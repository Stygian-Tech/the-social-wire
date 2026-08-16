import AsyncHTTPClient
import ArgumentParser
import Foundation
import Logging
import OperationsCore
import PostgresNIO
import ThinAppViewCore

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct CharybdisCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Charybdis, The Social Wire ingestion service"
  )

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.appview-worker")
    logger.logLevel = .info
    let workerLogger = logger

    let environment = RuntimeEnvironment.mergeProcessWithDotenv()
    let operationsEnvironment = try OperationsConfiguration.requireEnvironment(environment)
    let thinConfig = ThinAppViewConfig.fromEnvironment(environment)
    let tapConfiguration = try TapConsumerConfiguration.fromEnvironment(environment)
    let operationsConfig = OperationsConfiguration.fromEnvironment(environment)
    let listenPort = port ?? Int(environment["PORT"] ?? "8082") ?? 8082
    let listenHost = hostname ?? environment["BIND_HOST"] ?? "::"
    guard thinConfig.enabled else {
      throw WorkerRuntimeError.thinAppViewDisabled
    }

    let proactiveExtraAuthorDids = (environment["THIN_APPVIEW_PROACTIVE_BACKFILL_AUTHOR_DIDS"] ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let backend = try DatabaseBackend.fromEnvironment(environment)
    let plcURL = environment["ATPROTO_PLC_URL"] ?? "https://plc.directory"
    let httpClient = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: Self.httpClientConfiguration()
    )
    defer { Task { try? await httpClient.shutdown() } }

    switch backend {
    case .sqlite(let path):
      let store = try SQLiteThinAppViewStore(path: path, logger: workerLogger)
      let operationsStore = try SQLiteOperationsStore(
        path: path,
        environment: operationsEnvironment,
        backfillFingerprintSecret: operationsConfig.backfillFingerprintSecret,
        logger: workerLogger
      )
      let telemetry = OperationsTelemetryBuffer(store: operationsStore, logger: workerLogger)
      let cacheBackend = try AppViewProjectionCacheBackend.fromEnvironment(
        environment,
        default: .sqlite
      )
      let redisRuntime = cacheBackend == .redis
        ? RedisProjectionCacheRuntime.make(
          environment: environment,
          appEnvironment: operationsEnvironment,
          logger: workerLogger,
          telemetry: RedisOperationsTelemetryAdapter.sink(
            telemetry: operationsConfig.enabled ? telemetry : nil,
            service: "charybdis"
          )
        )
        : nil
      let projectionCache: (any AppViewProjectionCacheStore)? = if cacheBackend == .redis {
        redisRuntime?.store
      } else {
        try SQLiteAppViewProjectionCacheStore(path: path, logger: workerLogger)
      }
      await redisRuntime?.installResolutionCache()
      let readinessProbe = Self.readinessProbe(
        storePing: { try await store.ping() },
        operationsStore: operationsStore,
        operationsConfig: operationsConfig
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await WorkerHealthServer.run(
            startupProbe: { try await store.ping() },
            readinessProbe: { try await readinessProbe.run() },
            host: listenHost,
            port: listenPort,
            logger: workerLogger
          )
        }
        group.addTask {
          try await ThinAppViewWorkerRuntime.run(
            store: store,
            config: thinConfig,
            logger: workerLogger,
            httpClient: httpClient,
            plcURL: plcURL,
            proactiveExtraAuthorDids: proactiveExtraAuthorDids,
            projectionCache: projectionCache,
            operationsStore: operationsStore,
            operationsConfig: operationsConfig,
            tapConfiguration: tapConfiguration
          )
        }
        try await group.next()
        group.cancelAll()
      }
      await redisRuntime?.shutdown()

    case .postgres(let urlString):
      let pgConfig = try makePostgresConfig(from: urlString, logger: workerLogger)
      let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: workerLogger)
      let store = PostgresThinAppViewStore(pool: pgPool, logger: workerLogger)
      let operationsStore = PostgresOperationsStore(
        pool: pgPool,
        environment: operationsEnvironment,
        backfillFingerprintSecret: operationsConfig.backfillFingerprintSecret,
        logger: workerLogger
      )
      let telemetry = OperationsTelemetryBuffer(store: operationsStore, logger: workerLogger)
      let cacheBackend = try AppViewProjectionCacheBackend.fromEnvironment(
        environment,
        default: .postgres
      )
      let redisRuntime = cacheBackend == .redis
        ? RedisProjectionCacheRuntime.make(
          environment: environment,
          appEnvironment: operationsEnvironment,
          logger: workerLogger,
          telemetry: RedisOperationsTelemetryAdapter.sink(
            telemetry: operationsConfig.enabled ? telemetry : nil,
            service: "charybdis"
          )
        )
        : nil
      let projectionCache: (any AppViewProjectionCacheStore)? = cacheBackend == .redis
        ? redisRuntime?.store
        : PostgresAppViewProjectionCacheStore(pool: pgPool, logger: workerLogger)
      await redisRuntime?.installResolutionCache()
      let readinessProbe = Self.readinessProbe(
        storePing: { try await store.ping() },
        operationsStore: operationsStore,
        operationsConfig: operationsConfig
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pgPool.run() }
        group.addTask {
          try await WorkerHealthServer.run(
            startupProbe: { try await store.ping() },
            readinessProbe: { try await readinessProbe.run() },
            host: listenHost,
            port: listenPort,
            logger: workerLogger
          )
        }
        group.addTask {
          try await ThinAppViewWorkerRuntime.run(
            store: store,
            config: thinConfig,
            logger: workerLogger,
            httpClient: httpClient,
            plcURL: plcURL,
            proactiveExtraAuthorDids: proactiveExtraAuthorDids,
            projectionCache: projectionCache,
            operationsStore: operationsStore,
            operationsConfig: operationsConfig,
            tapConfiguration: tapConfiguration
          )
        }
        try await group.next()
        group.cancelAll()
      }
      await redisRuntime?.shutdown()
    }
  }

  static func httpClientConfiguration() -> HTTPClient.Configuration {
    var configuration = HTTPClient.Configuration()
    // Per-request deadlines stop at response headers. An idle read deadline also releases an
    // ingestion lane when a PDS or proxy sends headers and then stalls the response body.
    configuration.timeout.read = .seconds(30)
    // Shared PDS hosts should not reduce a wider durable-inbox pool back to AHC's default of eight.
    configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 50
    return configuration
  }

  private static func readinessProbe(
    storePing: @escaping @Sendable () async throws -> Void,
    operationsStore: any OperationsStore,
    operationsConfig: OperationsConfiguration
  ) -> WorkerReadinessProbe {
    let serviceStateProbe: (@Sendable () async throws -> OperationsServiceState?)?
    if operationsConfig.enabled {
      serviceStateProbe = {
        try await operationsStore.listServiceStates()
          .filter {
            $0.service == "appview-worker"
              && $0.environment == operationsConfig.environment
              && $0.instanceId == operationsConfig.instanceId
          }
          .max(by: { $0.heartbeatAt < $1.heartbeatAt })
      }
    } else {
      serviceStateProbe = nil
    }
    return WorkerReadinessProbe(
      databaseProbe: storePing,
      serviceStateProbe: serviceStateProbe
    )
  }

}

enum WorkerRuntimeError: Error, CustomStringConvertible {
  case thinAppViewDisabled

  var description: String {
    "ENABLE_THIN_APPVIEW must be true to run Charybdis."
  }
}
