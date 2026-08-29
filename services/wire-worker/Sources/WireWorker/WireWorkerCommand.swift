import ArgumentParser
import AsyncHTTPClient
import Foundation
import Logging
import PostgresNIO

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct WireWorkerCommand: AsyncParsableCommand {
  private enum HealthError: Error { case runtimeStale }
  static let configuration = CommandConfiguration(
    abstract: "Materialize The Wire"
  )

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    LoggingSystem.bootstrap { RailwaySeverityLogHandler(label: $0) }
    var logger = Logger(label: "com.thesocialwire.wire-worker")
    logger.logLevel = .info
    let serviceLogger = logger
    let environment = ProcessInfo.processInfo.environment
    let config = try WireWorkerConfig.load(environment)
    let runtimePlan = WireWorkerRuntimePlan(
      mode: config.mode,
      role: config.role,
      cleanupEnabled: config.inboxCleanupEnabled
    )
    if runtimePlan.runsGeneration { try config.ranking.validate() }
    let postgresConfig = try PostgresWireConfig.make(
      from: config.databaseURL,
      maximumConnections: config.postgresMaximumConnections,
      logger: serviceLogger
    )
    let pool = PostgresClient(configuration: postgresConfig, backgroundLogger: serviceLogger)
    let store = PostgresWireGenerationStore(pool: pool, logger: serviceLogger)
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let publicRepoClient = HTTPWirePublicationQueryClient(httpClient: httpClient)
    let publicationResolver = WirePublicationResolver(
      store: PostgresWirePublicationMetadataStore(pool: pool, logger: serviceLogger),
      queryClient: publicRepoClient
    )
    let linkMetadataStore = PostgresWireLinkMetadataStore(pool: pool, logger: serviceLogger)
    let inboxProcessor: PostgresWireInboxProcessor?
    if let actorSecret = config.actorHMACSecret {
      inboxProcessor = try PostgresWireInboxProcessor(
        pool: pool,
        logger: serviceLogger,
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
      let labelStore = PostgresWireBaselineLabelStore(pool: pool, logger: serviceLogger)
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
    let host = hostname ?? environment["BIND_HOST"] ?? "::"
    let port = port ?? Int(environment["PORT"] ?? "8080") ?? 8080

    serviceLogger.info(
      "Starting The Wire worker",
      metadata: [
        "mode": .string(config.mode.rawValue),
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
        group.addTask {
          try await WireHealthServer.run(
            databaseProbe: { try await store.ping() },
            readinessProbe: {
              let now = Date()
              if runtimePlan.requiresDrainReadiness {
                guard await state.isDrainReady(
                  at: now,
                  maximumSuccessAge: 60,
                  maximumOperationAge: 180
                ) else { throw HealthError.runtimeStale }
              }
              if runtimePlan.requiresCleanupReadiness {
                guard await state.isCleanupReady(
                  at: now, maximumSuccessAge: 60, maximumOperationAge: 180
                ) else { throw HealthError.runtimeStale }
              }
              if runtimePlan.requiresGenerationReadiness {
                guard await state.isGenerationReady(
                  at: now,
                  maximumCycleAge: TimeInterval(max(config.intervalSeconds * 2, 600))
                ) else { throw HealthError.runtimeStale }
              }
            },
            host: host,
            port: port,
            logger: serviceLogger
          )
        }
        if let cycle {
          group.addTask {
            try await WireWorkerRuntime.runForever(cycle: cycle, state: state, logger: serviceLogger)
          }
        }
        if runtimePlan.runsDrain, let inboxProcessor {
          group.addTask {
            try await WireInboxDrainRuntime.run(
              processor: inboxProcessor,
              state: state,
              logger: serviceLogger,
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
              logger: serviceLogger
            )
          }
        }
        if runtimePlan.runsCleanup, let inboxProcessor {
          group.addTask {
            try await WireInboxCleanupRuntime.run(
              cleaner: inboxProcessor,
              state: state,
              logger: serviceLogger,
              batchSize: config.inboxCleanupBatchSize,
              idleMilliseconds: config.inboxCleanupIdleMilliseconds
            )
          }
        }
        if runtimePlan.runsMetadataEnrichment {
          let enricher = WireLinkMetadataEnricher(
            store: linkMetadataStore,
            client: HTTPWireLinkMetadataClient(httpClient: httpClient),
            logger: serviceLogger,
            batchSize: config.metadataBatchSize,
            maximumConcurrentFetches: config.metadataConcurrency
          )
          group.addTask {
            try await WireMetadataEnrichmentRuntime.run(
              enricher: enricher,
              logger: serviceLogger,
              idleMilliseconds: config.metadataIdleMilliseconds
            )
          }
          let profileEnricher = WireTalkedAccountProfileEnricher(
            store: PostgresWireTalkedAccountProfileStore(pool: pool, logger: serviceLogger),
            client: HTTPWireTalkedAccountProfileClient(httpClient: httpClient),
            logger: serviceLogger,
            batchSize: min(config.metadataBatchSize, 100),
            maximumConcurrentFetches: min(config.metadataConcurrency, 8)
          )
          group.addTask {
            try await WireMetadataEnrichmentRuntime.runProfiles(
              enricher: profileEnricher,
              logger: serviceLogger,
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
