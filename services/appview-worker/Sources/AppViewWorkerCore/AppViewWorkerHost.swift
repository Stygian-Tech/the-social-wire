import AsyncHTTPClient
import Foundation
import Logging
import OperationsCore
import PostgresNIO
import ThinAppViewCore

public enum AppViewWorkerHealthListener: Sendable, Equatable {
  case disabled
  case enabled(hostname: String?, port: Int?)
}

public enum AppViewWorkerHost {
  public static func run(
    environment: [String: String],
    role: ThinAppViewWorkerRole = .combined,
    serviceName: String = "appview-worker",
    healthListener: AppViewWorkerHealthListener = .disabled,
    logger: Logger
  ) async throws {
    let operationsEnvironment = try OperationsConfiguration.requireEnvironment(environment)
    let thinConfig = ThinAppViewConfig.fromEnvironment(environment)
    let tapConfiguration = try TapConsumerConfiguration.fromEnvironment(environment)
    let operationsConfig = OperationsConfiguration.fromEnvironment(environment)
    guard thinConfig.enabled else {
      throw AppViewWorkerRuntimeError.thinAppViewDisabled
    }

    let proactiveExtraAuthorDids = (environment["THIN_APPVIEW_PROACTIVE_BACKFILL_AUTHOR_DIDS"] ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let backend = try DatabaseBackend.fromEnvironment(environment)
    let plcURL = environment["ATPROTO_PLC_URL"] ?? "https://plc.directory"
    let httpClient = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: httpClientConfiguration()
    )
    defer { Task { try? await httpClient.shutdown() } }

    switch backend {
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
          appEnvironment: operationsEnvironment,
          logger: logger,
          telemetry: RedisOperationsTelemetryAdapter.sink(
            telemetry: operationsConfig.enabled ? telemetry : nil,
            service: serviceName
          )
        )
        : nil
      let projectionCache: (any AppViewProjectionCacheStore)? = if cacheBackend == .redis {
        redisRuntime?.store
      } else {
        try SQLiteAppViewProjectionCacheStore(path: path, logger: logger)
      }
      await redisRuntime?.installResolutionCache()
      let readinessProbe = readinessProbe(
        storePing: { try await store.ping() },
        operationsStore: operationsStore,
        operationsConfig: operationsConfig,
        serviceName: serviceName
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        addHealthListener(
          healthListener,
          environment: environment,
          startupProbe: { try await store.ping() },
          readinessProbe: { try await readinessProbe.run(includingDiagnostics: true) },
          logger: logger,
          to: &group
        )
        group.addTask {
          try await ThinAppViewWorkerRuntime.run(
            store: store,
            config: thinConfig,
            role: role,
            serviceName: serviceName,
            logger: logger,
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
      let pgConfig = try makePostgresConfig(from: urlString, logger: logger)
      let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: logger)
      let store = PostgresThinAppViewStore(pool: pgPool, logger: logger)
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
          appEnvironment: operationsEnvironment,
          logger: logger,
          telemetry: RedisOperationsTelemetryAdapter.sink(
            telemetry: operationsConfig.enabled ? telemetry : nil,
            service: serviceName
          )
        )
        : nil
      let projectionCache: (any AppViewProjectionCacheStore)? = cacheBackend == .redis
        ? redisRuntime?.store
        : PostgresAppViewProjectionCacheStore(pool: pgPool, logger: logger)
      await redisRuntime?.installResolutionCache()
      let readinessProbe = readinessProbe(
        storePing: { try await store.ping() },
        operationsStore: operationsStore,
        operationsConfig: operationsConfig,
        serviceName: serviceName
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pgPool.run() }
        addHealthListener(
          healthListener,
          environment: environment,
          startupProbe: { try await store.ping() },
          readinessProbe: { try await readinessProbe.run(includingDiagnostics: true) },
          logger: logger,
          to: &group
        )
        group.addTask {
          try await ThinAppViewWorkerRuntime.run(
            store: store,
            config: thinConfig,
            role: role,
            serviceName: serviceName,
            logger: logger,
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
    configuration.timeout.read = .seconds(30)
    configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 50
    return configuration
  }

  private static func readinessProbe(
    storePing: @escaping @Sendable () async throws -> Void,
    operationsStore: any OperationsStore,
    operationsConfig: OperationsConfiguration,
    serviceName: String
  ) -> WorkerReadinessProbe {
    let serviceStateProbe: (@Sendable () async throws -> OperationsServiceState?)?
    if operationsConfig.enabled {
      serviceStateProbe = {
        try await operationsStore.listServiceStates()
          .filter {
            $0.service == serviceName
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

  private static func addHealthListener(
    _ listener: AppViewWorkerHealthListener,
    environment: [String: String],
    startupProbe: @escaping @Sendable () async throws -> Void,
    readinessProbe: @escaping @Sendable () async throws -> Void,
    logger: Logger,
    to group: inout ThrowingTaskGroup<Void, any Error>
  ) {
    guard case .enabled(let configuredHostname, let configuredPort) = listener else { return }
    let host = configuredHostname ?? environment["BIND_HOST"] ?? "::"
    let port = configuredPort ?? Int(environment["PORT"] ?? "8082") ?? 8082
    group.addTask {
      try await WorkerHealthServer.run(
        startupProbe: startupProbe,
        readinessProbe: readinessProbe,
        host: host,
        port: port,
        logger: logger
      )
    }
  }
}

public enum AppViewWorkerRuntimeError: Error, CustomStringConvertible {
  case thinAppViewDisabled

  public var description: String {
    "ENABLE_THIN_APPVIEW must be true to run Charybdis."
  }
}
