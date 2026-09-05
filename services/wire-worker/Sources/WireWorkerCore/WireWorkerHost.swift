import AsyncHTTPClient
import Foundation
import Logging
import PostgresNIO

public enum WireWorkerHealthListener: Sendable {
  case disabled
  case enabled(hostname: String, port: Int)
}

public enum WireWorkerHost {
  private enum HealthError: Error { case runtimeStale }

  public static func run(
    environment: [String: String],
    role: WireWorkerRole? = nil,
    healthListener: WireWorkerHealthListener = .disabled,
    logger: Logger
  ) async throws {
    let config = try WireWorkerConfig.load(environment, role: role)
    let runtimePlan = WireWorkerRuntimePlan(
      mode: config.mode,
      role: config.role,
      cleanupEnabled: config.inboxCleanupEnabled
    )
    if runtimePlan.runsGeneration {
      for plan in config.externalSignalMode.generationPlans(baseline: config.ranking) {
        try plan.config.validate()
      }
    }

    let postgresConfig = try PostgresWireConfig.make(
      from: config.databaseURL,
      maximumConnections: config.postgresMaximumConnections,
      environment: environment,
      logger: logger
    )
    let pool = PostgresClient(configuration: postgresConfig, backgroundLogger: logger)
    let store = PostgresWireGenerationStore(pool: pool, logger: logger)
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let publicRepoClient = HTTPWirePublicationQueryClient(httpClient: httpClient)
    let publicationResolver = WirePublicationResolver(
      store: PostgresWirePublicationMetadataStore(pool: pool, logger: logger),
      queryClient: publicRepoClient
    )
    let linkMetadataStore = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    let inboxProcessor: PostgresWireInboxProcessor?
    if let actorSecret = config.actorHMACSecret {
      inboxProcessor = try PostgresWireInboxProcessor(
        pool: pool,
        logger: logger,
        actorSecret: actorSecret,
        publicationResolver: publicationResolver,
        blobURLResolver: publicRepoClient,
        linkMetadataStore: linkMetadataStore,
        batchSize: config.inboxBatchSize,
        maximumConcurrentEvents: config.inboxConcurrency,
        sourceScope: config.inboxSourceScope
      )
    } else {
      inboxProcessor = nil
    }
    let drainTelemetry =
      runtimePlan.runsDrain
      ? WireInboxDrainTelemetryState(startedAt: Date()) : nil
    let cycle: WireWorkerCycle?
    if runtimePlan.runsGeneration {
      let labelStore = PostgresWireBaselineLabelStore(pool: pool, logger: logger)
      let labelRefresher = WireBaselineLabelRefresher(
        store: labelStore,
        queryClient: HTTPWireLabelQueryClient(httpClient: httpClient),
        labelers: config.baselineLabelers,
        candidateLimit: config.candidateLimit,
        maximumAge: TimeInterval(config.labelRefreshMaximumAgeSeconds)
      )
      cycle = WireWorkerCycle(
        store: store,
        config: config,
        inboxMaintainer: inboxProcessor,
        labelRefresher: labelRefresher
      )
    } else {
      cycle = nil
    }
    let state = WireWorkerHealthState()

    logger.info(
      "Starting The Wire worker",
      metadata: [
        "mode": .string(config.mode.rawValue),
        "external_signal_mode": .string(config.externalSignalMode.rawValue),
        "serving_algorithm_version": .string(
          config.externalSignalMode.generationPlans(baseline: config.ranking)
            .first(where: \.activationEligible)?.config.version ?? config.ranking.version
        ),
        "role": .string(config.role.rawValue),
        "inbox_source_scope": .string(
          config.inboxSourceScope.map {
            "\($0.environment):\($0.sourceGenerations.joined(separator: ","))"
          } ?? "all"
        ),
      ]
    )

    var runtimeError: Error?
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pool.run() }
        if case .enabled(let hostname, let port) = healthListener {
          group.addTask {
            try await WireHealthServer.run(
              databaseProbe: { try await store.ping() },
              readinessProbe: {
                let now = Date()
                if runtimePlan.requiresDrainReadiness {
                  guard
                    await state.isDrainReady(
                      at: now,
                      maximumSuccessAge: 60,
                      maximumOperationAge: 180
                    )
                  else { throw HealthError.runtimeStale }
                }
                if runtimePlan.requiresCleanupReadiness {
                  guard
                    await state.isCleanupReady(
                      at: now, maximumSuccessAge: 60, maximumOperationAge: 180
                    )
                  else { throw HealthError.runtimeStale }
                }
                if runtimePlan.requiresGenerationReadiness {
                  guard
                    await state.isGenerationReady(
                      at: now,
                      maximumCycleAge: TimeInterval(max(config.intervalSeconds * 2, 600))
                    )
                  else { throw HealthError.runtimeStale }
                }
              },
              host: hostname,
              port: port,
              logger: logger
            )
          }
        }
        if let cycle {
          group.addTask {
            try await WireWorkerRuntime.runForever(
              cycle: cycle, state: state, logger: logger)
          }
        }
        if runtimePlan.runsDrain, let inboxProcessor {
          group.addTask {
            try await WireInboxDrainRuntime.run(
              processor: inboxProcessor,
              state: state,
              logger: logger,
              configuration: .init(idleMilliseconds: config.inboxIdleMilliseconds),
              telemetry: drainTelemetry
            )
          }
        }
        if runtimePlan.runsDrain, let inboxProcessor, let drainTelemetry {
          group.addTask {
            try await WireInboxDrainTelemetryRuntime.run(
              observer: inboxProcessor,
              telemetry: drainTelemetry,
              logger: logger
            )
          }
        }
        if runtimePlan.runsCleanup, let inboxProcessor {
          group.addTask {
            try await WireInboxCleanupRuntime.run(
              cleaner: inboxProcessor,
              state: state,
              logger: logger,
              batchSize: config.inboxCleanupBatchSize,
              idleMilliseconds: config.inboxCleanupIdleMilliseconds
            )
          }
        }
        if runtimePlan.runsGraphMaintenance, let inboxProcessor {
          group.addTask {
            try await WireGraphMaintenanceRuntime.run(
              maintainer: inboxProcessor, state: state, logger: logger)
          }
        }
        if runtimePlan.runsMetadataEnrichment {
          let enricher = WireLinkMetadataEnricher(
            store: linkMetadataStore,
            client: HTTPWireLinkMetadataClient(httpClient: httpClient),
            logger: logger,
            batchSize: config.metadataBatchSize,
            maximumConcurrentFetches: config.metadataConcurrency
          )
          group.addTask {
            try await WireMetadataEnrichmentRuntime.run(
              enricher: enricher,
              logger: logger,
              idleMilliseconds: config.metadataIdleMilliseconds
            )
          }
          let profileEnricher = WireTalkedAccountProfileEnricher(
            store: PostgresWireTalkedAccountProfileStore(pool: pool, logger: logger),
            client: HTTPWireTalkedAccountProfileClient(httpClient: httpClient),
            logger: logger,
            batchSize: min(config.metadataBatchSize, 100),
            maximumConcurrentFetches: min(config.metadataConcurrency, 8)
          )
          group.addTask {
            try await WireMetadataEnrichmentRuntime.runProfiles(
              enricher: profileEnricher,
              logger: logger,
              idleMilliseconds: config.metadataIdleMilliseconds
            )
          }
        }
        try await group.next()
        group.cancelAll()
      }
    } catch {
      runtimeError = error
    }
    try? await httpClient.shutdown()
    if let runtimeError { throw runtimeError }
  }
}
