import ArgumentParser
import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import OperationsCore
import PostgresNIO
import ThinAppViewCore

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct GatewayCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The Social Wire Gateway (OAuth, sync, PDS writes)",
    subcommands: [Serve.self],
    defaultSubcommand: Serve.self
  )
}

struct Serve: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Run the gateway HTTP server")

  @Option(name: .long, help: "Port to bind on")
  var port: Int?

  @Option(name: .long, help: "Hostname to bind on")
  var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.gateway")
    logger.logLevel = .info

    let environment = AppEnvironmentLoader.mergeProcessWithDotenv()
    let operationsEnvironment = try OperationsConfiguration.requireEnvironment(environment)
    let config = GatewayServiceConfig.fromEnvironment(environment)
    let operationsConfig = OperationsConfiguration.fromEnvironment(environment)
    let listenPort = port ?? Int(environment["PORT"] ?? "8080") ?? 8080
    let listenHost = hostname ?? environment["BIND_HOST"] ?? "0.0.0.0"

    logger.info(
      "Starting Social Wire Gateway",
      metadata: [
        "env": .string(config.core.appEnv.rawValue),
        "appview_proxy": .string(config.appViewBaseURL ?? "disabled"),
        "port": .string("\(listenPort)"),
      ]
    )

    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let dependencyProbe = Self.gatewayDependencyProbe(
      appViewBaseURL: config.appViewBaseURL,
      httpClient: httpClient
    )
    var serverError: Error?
    do {
      switch config.cacheBackend {
      case .sqlite(let path):
        let cache = try SQLiteCache(path: path, logger: logger)
        let operationsStore = try SQLiteOperationsStore(
          path: path,
          environment: operationsEnvironment,
          backfillFingerprintSecret: operationsConfig.backfillFingerprintSecret,
          logger: logger
        )
        let telemetry = OperationsTelemetryBuffer(store: operationsStore, logger: logger)
        let heartbeat = OperationsHeartbeatJob(
          store: operationsStore,
          service: "gateway",
          environment: operationsEnvironment,
          instanceId: operationsConfig.instanceId,
          dependencyProbe: dependencyProbe,
          telemetry: telemetry,
          logger: logger
        )
        let router = GatewayRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          cache: cache,
          operationsStore: operationsStore,
          telemetry: operationsConfig.enabled ? telemetry : nil,
          telemetryEnvironment: operationsEnvironment,
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
          try await group.next()
          group.cancelAll()
        }

      case .postgres(let urlString):
        let pgConfig = try makePostgresConfig(from: urlString, logger: logger)
        let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: logger)
        let cache = SupabaseCache(pool: pgPool, logger: logger)
        let operationsStore = PostgresOperationsStore(
          pool: pgPool,
          environment: operationsEnvironment,
          backfillFingerprintSecret: operationsConfig.backfillFingerprintSecret,
          logger: logger
        )
        let telemetry = OperationsTelemetryBuffer(store: operationsStore, logger: logger)
        let heartbeat = OperationsHeartbeatJob(
          store: operationsStore,
          service: "gateway",
          environment: operationsEnvironment,
          instanceId: operationsConfig.instanceId,
          dependencyProbe: dependencyProbe,
          telemetry: telemetry,
          logger: logger
        )
        let router = GatewayRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          cache: cache,
          operationsStore: operationsStore,
          telemetry: operationsConfig.enabled ? telemetry : nil,
          telemetryEnvironment: operationsEnvironment,
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
          try await group.next()
          group.cancelAll()
        }
      }
    } catch {
      serverError = error
    }
    try? await httpClient.shutdown()
    if let serverError { throw serverError }
  }

  static func gatewayDependencyProbe(
    appViewBaseURL: String?,
    httpClient: HTTPClient
  ) -> OperationsServiceDependencyProbe {
    let normalizedBase = appViewBaseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return {
      let observedAt = Date()
      guard let normalizedBase, !normalizedBase.isEmpty else {
        return OperationsServiceProbeResult(
          liveness: .healthy,
          readiness: .unknown,
          freshness: .unknown,
          completeness: .unknown,
          dependencyState: ["appview": "missing"],
          observedAt: observedAt,
          validUntil: observedAt.addingTimeInterval(30)
        )
      }

      var request = HTTPClientRequest(url: "\(normalizedBase)/readyz")
      request.method = .GET
      let response = try await httpClient.execute(request, timeout: .seconds(5))
      _ = try await response.body.collect(upTo: 4 * 1024)
      let ready = (200..<300).contains(Int(response.status.code))
      return OperationsServiceProbeResult(
        liveness: .healthy,
        readiness: ready ? .healthy : .degraded,
        freshness: .unknown,
        completeness: .unknown,
        dependencyState: [
          "appview": ready ? "ready" : "failed_http_\(response.status.code)",
          "appview_projection_freshness": "unmeasured",
          "appview_projection_completeness": "unmeasured",
        ],
        observedAt: observedAt,
        validUntil: observedAt.addingTimeInterval(30)
      )
    }
  }
}
