import ArgumentParser
import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import OperationsCore
import PostgresNIO
import ThinAppViewCore
import WireCore

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AppViewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The Social Wire AppView (projection reads, thin index)",
    subcommands: [Serve.self],
    defaultSubcommand: Serve.self
  )
}

struct Serve: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Run the AppView HTTP server")

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.appview")
    logger.logLevel = .info

    let environment = AppEnvironmentLoader.mergeProcessWithDotenv()
    let operationsEnvironment = try OperationsConfiguration.requireEnvironment(environment)
    let config = try AppViewServiceConfig.fromEnvironment(environment)
    let operationsConfig = OperationsConfiguration.fromEnvironment(environment)
    let listenPort = port ?? Int(environment["PORT"] ?? "8081") ?? 8081
    let listenHost = hostname ?? environment["BIND_HOST"] ?? "::"

    guard config.thinAppView.enabled else {
      throw AppViewStartupError.thinAppViewDisabled
    }

    logger.info(
      "Starting Social Wire AppView",
      metadata: [
        "env": .string(config.core.appEnv.rawValue),
        "port": .string("\(listenPort)"),
      ]
    )

    // Projection rebuilds fan out across a handful of hosts (PLC, the large shared PDSes, the
    // public relay), so the default 8-connections-per-host soft limit caps the whole pipeline no
    // matter how wide its task groups are.
    var httpConfiguration = HTTPClient.Configuration()
    httpConfiguration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 50
    let httpClient = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: httpConfiguration
    )
    var serverError: Error?
    do {
      switch config.storeBackend {
      case .sqlite(let path):
        let store = try SQLiteThinAppViewStore(path: path, logger: logger)
        let operationsStore = try SQLiteOperationsStore(
          path: path,
          environment: operationsEnvironment,
          backfillFingerprintSecret: operationsConfig.backfillFingerprintSecret,
          logger: logger
        )
        let telemetry = OperationsTelemetryBuffer(store: operationsStore, logger: logger)
        let cacheBackend = try AppViewProjectionCacheBackend.fromEnvironment(
          environment,
          default: .sqlite
        )
        let redisRuntime = cacheBackend == .redis
          ? RedisProjectionCacheRuntime.make(
            environment: environment,
            appEnvironment: config.core.appEnv.rawValue,
            logger: logger,
            telemetry: RedisOperationsTelemetryAdapter.sink(
              telemetry: operationsConfig.enabled ? telemetry : nil,
              service: "appview"
            )
          )
          : nil
        let projectionCache: (any AppViewProjectionCacheStore)? = if cacheBackend == .redis {
          redisRuntime?.store
        } else {
          try SQLiteAppViewProjectionCacheStore(path: path, logger: logger)
        }
        await redisRuntime?.installResolutionCache()
        let heartbeat = OperationsHeartbeatJob(
          store: operationsStore,
          service: "appview",
          environment: operationsConfig.environment,
          instanceId: operationsConfig.instanceId,
          dependencyProbe: appViewDependencyProbe(store: store),
          telemetry: telemetry,
          logger: logger
        )
        let router = AppViewRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          thinAppViewStore: store,
          wireFeedStore: nil,
          wireModerationService: nil,
          projectionCache: projectionCache,
          operationsStore: operationsStore,
          telemetry: operationsConfig.enabled ? telemetry : nil,
          telemetryEnvironment: operationsConfig.environment,
          telemetryInstanceId: operationsConfig.instanceId,
          logger: logger
        )
        let app = Application(
          router: router,
          configuration: .init(address: .hostname(listenHost, port: listenPort))
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { try await app.run() }
          if operationsConfig.enabled { group.addTask { await telemetry.runForever() } }
          if operationsConfig.enabled { group.addTask { await heartbeat.runForever() } }
          if let redisRuntime { group.addTask { await redisRuntime.runInfoSampling() } }
          try await group.next()
          group.cancelAll()
        }
        await redisRuntime?.shutdown()

      case .postgres(let urlString):
        let pgConfig = try makePostgresConfig(from: urlString, logger: logger)
        let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: logger)
        let store = PostgresThinAppViewStore(pool: pgPool, logger: logger)
        let wireFeedStore: (any WireFeedStore)?
        let wireModerationService: WireViewerModerationService?
        if config.wire.mode.servesAPI {
          guard let cursorSecret = config.wire.cursorSecret else {
            throw AppViewStartupError.missingWireCursorSecret
          }
          let moderationCache = WireViewerModerationCache()
          if let corpusEdge = config.wire.corpusEdge {
            wireFeedStore = try RemoteWireFeedStore(
              transport: HTTPWireCorpusTransport(config: corpusEdge, httpClient: httpClient),
              cursorSecret: cursorSecret,
              mode: config.wire.mode,
              moderationCache: moderationCache
            )
          } else {
            wireFeedStore = try PostgresWireFeedStore(
              pool: pgPool,
              logger: logger,
              cursorSecret: cursorSecret,
              mode: config.wire.mode,
              moderationCache: moderationCache
            )
          }
          wireModerationService = WireViewerModerationService(
            httpClient: httpClient,
            plcURL: config.core.atprotoPLCURL,
            cache: moderationCache,
            logger: logger
          )
        } else {
          wireFeedStore = nil
          wireModerationService = nil
        }
        let operationsStore = PostgresOperationsStore(
          pool: pgPool,
          environment: operationsEnvironment,
          backfillFingerprintSecret: operationsConfig.backfillFingerprintSecret,
          logger: logger
        )
        let telemetry = OperationsTelemetryBuffer(store: operationsStore, logger: logger)
        let cacheBackend = try AppViewProjectionCacheBackend.fromEnvironment(
          environment,
          default: .postgres
        )
        let redisRuntime = cacheBackend == .redis
          ? RedisProjectionCacheRuntime.make(
            environment: environment,
            appEnvironment: config.core.appEnv.rawValue,
            logger: logger,
            telemetry: RedisOperationsTelemetryAdapter.sink(
              telemetry: operationsConfig.enabled ? telemetry : nil,
              service: "appview"
            )
          )
          : nil
        let projectionCache: (any AppViewProjectionCacheStore)? = cacheBackend == .redis
          ? redisRuntime?.store
          : PostgresAppViewProjectionCacheStore(pool: pgPool, logger: logger)
        await redisRuntime?.installResolutionCache()
        let heartbeat = OperationsHeartbeatJob(
          store: operationsStore,
          service: "appview",
          environment: operationsConfig.environment,
          instanceId: operationsConfig.instanceId,
          dependencyProbe: appViewDependencyProbe(store: store),
          telemetry: telemetry,
          logger: logger
        )
        let router = AppViewRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          thinAppViewStore: store,
          wireFeedStore: wireFeedStore,
          wireModerationService: wireModerationService,
          projectionCache: projectionCache,
          operationsStore: operationsStore,
          telemetry: operationsConfig.enabled ? telemetry : nil,
          telemetryEnvironment: operationsConfig.environment,
          telemetryInstanceId: operationsConfig.instanceId,
          logger: logger
        )
        let app = Application(
          router: router,
          configuration: .init(address: .hostname(listenHost, port: listenPort))
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { await pgPool.run() }
          group.addTask { try await app.run() }
          if operationsConfig.enabled { group.addTask { await telemetry.runForever() } }
          if operationsConfig.enabled { group.addTask { await heartbeat.runForever() } }
          if let redisRuntime { group.addTask { await redisRuntime.runInfoSampling() } }
          try await group.next()
          group.cancelAll()
        }
        await redisRuntime?.shutdown()
      }
    } catch {
      serverError = error
    }
    try? await httpClient.shutdown()
    if let serverError { throw serverError }
  }
}

private func appViewDependencyProbe(
  store: any ThinAppViewStore
) -> OperationsServiceDependencyProbe {
  {
    try await store.ping()
    let observedAt = Date()
    return OperationsServiceProbeResult(
      liveness: .healthy,
      readiness: .healthy,
      freshness: .unknown,
      completeness: .unknown,
      dependencyState: [
        "appview_database": "ready",
        "projection_freshness": "unmeasured",
        "projection_completeness": "unknown",
      ],
      requiredDependencyKeys: ["appview_database"],
      observedAt: observedAt,
      validUntil: observedAt.addingTimeInterval(30)
    )
  }
}

enum AppViewStartupError: Error, CustomStringConvertible {
  case thinAppViewDisabled
  case missingWireCursorSecret

  var description: String {
    switch self {
    case .thinAppViewDisabled:
      "ENABLE_THIN_APPVIEW must be true for the AppView service."
    case .missingWireCursorSecret:
      "WIRE_CURSOR_HMAC_SECRET must contain at least 32 bytes when The Wire API is enabled."
    }
  }
}
