import ArgumentParser
import AsyncHTTPClient
import Foundation
import Logging
import PostgresNIO

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct WireWorkerCommand: AsyncParsableCommand {
  private enum HealthError: Error { case generationCycleStale }
  static let configuration = CommandConfiguration(
    abstract: "Materialize The Wire"
  )

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.wire-worker")
    logger.logLevel = .info
    let serviceLogger = logger
    let environment = ProcessInfo.processInfo.environment
    let config = try WireWorkerConfig.load(environment)
    try config.ranking.validate()
    let postgresConfig = try PostgresWireConfig.make(from: config.databaseURL, logger: serviceLogger)
    let pool = PostgresClient(configuration: postgresConfig, backgroundLogger: serviceLogger)
    let store = PostgresWireGenerationStore(pool: pool, logger: serviceLogger)
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let labelStore = PostgresWireBaselineLabelStore(pool: pool, logger: serviceLogger)
    let labelRefresher = WireBaselineLabelRefresher(
      store: labelStore,
      queryClient: HTTPWireLabelQueryClient(httpClient: httpClient),
      labelers: config.baselineLabelers,
      candidateLimit: config.candidateLimit,
      maximumAge: TimeInterval(config.labelRefreshMaximumAgeSeconds)
    )
    let inboxProcessor: PostgresWireInboxProcessor?
    if let actorSecret = config.actorHMACSecret {
      inboxProcessor = try PostgresWireInboxProcessor(
        pool: pool,
        logger: serviceLogger,
        actorSecret: actorSecret
      )
    } else {
      inboxProcessor = nil
    }
    let cycle = WireWorkerCycle(
      store: store,
      config: config,
      inboxProcessor: inboxProcessor,
      labelRefresher: labelRefresher
    )
    let state = WireWorkerHealthState()
    let host = hostname ?? environment["BIND_HOST"] ?? "::"
    let port = port ?? Int(environment["PORT"] ?? "8080") ?? 8080

    serviceLogger.info("Starting The Wire worker", metadata: ["mode": .string(config.mode.rawValue)])
    var runtimeError: Error?
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pool.run() }
        group.addTask {
          try await WireHealthServer.run(
            databaseProbe: { try await store.ping() },
            readinessProbe: {
              if config.mode != .off {
                let ready = await state.isReady(
                  at: Date(),
                  maximumCycleAge: TimeInterval(max(config.intervalSeconds * 2, 600))
                )
                guard ready else { throw HealthError.generationCycleStale }
              }
            },
            host: host,
            port: port,
            logger: serviceLogger
          )
        }
        group.addTask {
          try await WireWorkerRuntime.runForever(cycle: cycle, state: state, logger: serviceLogger)
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
