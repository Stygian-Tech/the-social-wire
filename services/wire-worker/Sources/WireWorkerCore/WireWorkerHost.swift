import AsyncHTTPClient
import Foundation
import Logging
import OperationsCore
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
    roleLeaseAuthority: RoleLeaseAuthority? = nil,
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
    let store = PostgresWireGenerationStore(pool: pool, logger: logger, roleLeaseAuthority: roleLeaseAuthority)
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let publicRepoClient = HTTPWirePublicationQueryClient(httpClient: httpClient)
    let publicationCache = WirePublicationCacheRuntime.make(environment: environment, logger: logger)
    let publicationResolver = WirePublicationResolver(
      store: PostgresWirePublicationMetadataStore(pool: pool, logger: logger),
      queryClient: publicRepoClient,
      cache: publicationCache?.cache,
      positiveCacheTTL: WirePublicationCacheRuntime.ttl(
        environment["WIRE_PUBLICATION_CACHE_TTL_SECONDS"], fallback: 60, maximum: 60),
      sharedNegativeCacheTTL: WirePublicationCacheRuntime.ttl(
        environment["WIRE_PUBLICATION_NEGATIVE_CACHE_TTL_SECONDS"], fallback: 15, maximum: 15)
    )
    let metadataScheduling = WireMetadataSchedulingConfiguration.load(environment)
    let linkMetadataStore = PostgresWireLinkMetadataStore(
      pool: pool, logger: logger, schedulingReadEnabled: metadataScheduling.readerEnabled,
      roleLeaseAuthority: roleLeaseAuthority)
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
        sourceScope: config.inboxSourceScope,
        deferredRecommendationsEnabled: config.deferredRecommendationsEnabled,
        dependencyVerificationEnabled: config.dependencyVerificationEnabled
      )
    } else {
      inboxProcessor = nil
    }
    let publicationRecovery: PostgresWirePublicationSignalRecovery?
    if runtimePlan.runsDrain, let actorSecret = config.actorHMACSecret, let scope = config.inboxSourceScope {
      publicationRecovery = try PostgresWirePublicationSignalRecovery(
        pool: pool, logger: logger, actorSecret: actorSecret, scope: scope)
    } else {
      publicationRecovery = nil
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

    try await WireWorkerLifetime.run(
      logger: logger, shutdown: {
        try? await publicationCache?.client.shutdown()
        try await httpClient.shutdown()
      }
    ) { group in
      if let publicationCache {
        group.addTask { try await publicationCache.runTelemetry(logger: logger) }
      }
      group.addTask {
        defer { logger.info("The Wire component stopped", metadata: ["component": "postgres"]) }
        await pool.run()
      }
      if case .enabled(let hostname, let port) = healthListener {
        group.addTask {
          defer { logger.info("The Wire component stopped", metadata: ["component": "health"]) }
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
          defer { logger.info("The Wire component stopped", metadata: ["component": "generation"]) }
          try await WireWorkerRuntime.runForever(
            cycle: cycle, state: state, logger: logger)
        }
      }
      if runtimePlan.runsDrain, let inboxProcessor {
        if let publicationRecovery {
          group.addTask {
            try await WirePublicationSignalRecoveryRuntime.run(recovery: publicationRecovery, logger: logger)
          }
        }
        group.addTask {
          defer { logger.info("The Wire component stopped", metadata: ["component": "drain"]) }
          try await WireInboxRepositoryDrainRuntime.run(
            processor: inboxProcessor,
            state: state,
            logger: logger,
            configuration: .init(
              maximumConcurrentEvents: config.inboxConcurrency,
              idleMilliseconds: config.inboxIdleMilliseconds),
            telemetry: drainTelemetry
          )
        }
      }
      if runtimePlan.runsDrain, let inboxProcessor, let drainTelemetry {
        group.addTask {
          defer { logger.info("The Wire component stopped", metadata: ["component": "drain-telemetry"]) }
          try await WireInboxDrainTelemetryRuntime.run(
            observer: inboxProcessor,
            telemetry: drainTelemetry,
            logger: logger
          )
        }
      }
      if runtimePlan.runsDrain, config.deferredRecommendationsEnabled {
        group.addTask {
          defer {
            logger.info("The Wire component stopped", metadata: ["component": "recommendation-recovery"])
          }
          try await WireRecommendationRecoveryRuntime.run(
            journal: PostgresWireRecommendationJournal(pool: pool, logger: logger,
              dependencyVerificationEnabled: config.dependencyVerificationEnabled),
            // Intake generations can retire while their logged dependencies remain.
            sourceScope: config.inboxSourceScope.map {
              WireInboxSourceScope(environment: $0.environment, sourceGenerations: [])
            },
            logger: logger)
        }
      }
      if runtimePlan.runsGraphMaintenance, config.role == .rank, config.dependencyVerificationEnabled,
        let recoveryEnvironment = config.dependencyRecoveryEnvironment,
        let actorSecret = config.actorHMACSecret, let inboxProcessor
      {
        group.addTask {
          let snapshots = try PostgresWireInboxProcessor(
            pool: pool, logger: logger, actorSecret: actorSecret,
            publicationResolver: publicationResolver, blobURLResolver: publicRepoClient,
            linkMetadataStore: linkMetadataStore, batchSize: 16, maximumConcurrentEvents: 2,
            sourceScope: WireInboxSourceScope(environment: recoveryEnvironment,
              sourceGenerations: [PostgresWireDependencyRecoveryStore.snapshotGeneration]),
            deferredRecommendationsEnabled: config.deferredRecommendationsEnabled,
            dependencyVerificationEnabled: true)
          let hydrator = WireRecommendationHydrator(pool: pool, logger: logger, environment: recoveryEnvironment,
            verifier: HTTPWirePublicRecordVerifier(httpClient: httpClient), processor: inboxProcessor)
          defer { logger.info("The Wire component stopped", metadata: ["component": "dependency-hydration"]) }
          try await WireRecommendationHydrationRuntime.run(hydrator: hydrator, snapshots: snapshots, logger: logger)
        }
      }
      if runtimePlan.runsCleanup, let inboxProcessor {
        group.addTask {
          defer { logger.info("The Wire component stopped", metadata: ["component": "cleanup"]) }
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
          defer { logger.info("The Wire component stopped", metadata: ["component": "graph"]) }
          try await WireGraphMaintenanceRuntime.run(
            maintainer: inboxProcessor, state: state, logger: logger)
        }
      }
      if runtimePlan.runsMetadataEnrichment {
        group.addTask {
          try await WireMetadataMaintenanceRuntime.runRepair(
            store: linkMetadataStore, logger: logger,
            intervalMilliseconds: metadataScheduling.repairIntervalMilliseconds)
        }
        if metadataScheduling.maintenanceEnabled {
          group.addTask {
            try await WireMetadataMaintenanceRuntime.runScheduling(store: linkMetadataStore, logger: logger)
          }
        }
        let enricher = WireLinkMetadataEnricher(
          store: linkMetadataStore,
          client: HTTPWireLinkMetadataClient(httpClient: httpClient),
          logger: logger,
          batchSize: config.metadataBatchSize,
          maximumConcurrentFetches: config.metadataConcurrency
        )
        group.addTask {
          defer { logger.info("The Wire component stopped", metadata: ["component": "metadata"]) }
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
          defer { logger.info("The Wire component stopped", metadata: ["component": "profiles"]) }
          try await WireMetadataEnrichmentRuntime.runProfiles(
            enricher: profileEnricher,
            logger: logger,
            idleMilliseconds: config.metadataIdleMilliseconds
          )
        }
      }
    }
  }
}
