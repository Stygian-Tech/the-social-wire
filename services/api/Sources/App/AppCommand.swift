// AppCommand.swift — program entry point with `serve` and `worker` subcommands.

import ArgumentParser
import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import NIOSSL
import PostgresNIO

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct App: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The Social Wire API Service",
    subcommands: [Serve.self, Worker.self],
    defaultSubcommand: Serve.self
  )
}

struct Serve: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Run the HTTP API server")

  @Option(name: .long, help: "Port to bind on (overrides PORT from environment / .env)")
  var port: Int?

  @Option(name: .long, help: "Hostname to bind on (overrides BIND_HOST from environment / .env)")
  var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.api")
    logger.logLevel = .info

    let environment = AppEnvironmentLoader.mergeProcessWithDotenv()
    let config = AppConfig.fromEnvironment(environment)

    let listenPort = port ?? Int(environment["PORT"] ?? "8080") ?? 8080
    let listenHost = hostname ?? environment["BIND_HOST"] ?? "0.0.0.0"

    logger.info(
      "Starting Social Wire API",
      metadata: [
        "env": .string(config.appEnv.rawValue),
        "backend": .string(config.cacheBackend.description),
        "legacy_content_api_enabled": .string(config.enableLegacyContentAPI ? "true" : "false"),
        "thin_appview_enabled": .string(config.thinAppView.enabled ? "true" : "false"),
        "port": .string("\(listenPort)"),
      ]
    )

    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

    var serverError: Error?
    do {
      switch config.cacheBackend {
      case .sqlite(let path):
        let cache = try SQLiteCache(path: path, logger: logger)
        let thinStore = try ThinAppViewBootstrap.makeStore(config: config, logger: logger, postgresPool: nil)
        let router = AppRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          cache: cache,
          logger: logger,
          thinAppViewStore: thinStore
        )
        let app = Application(
          router: router,
          configuration: .init(address: .hostname(listenHost, port: listenPort))
        )
        try await app.run()

      case .postgres(let urlString):
        let pgConfig = try makePostgresConfig(from: urlString, logger: logger)
        let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: logger)
        let cache = SupabaseCache(pool: pgPool, logger: logger)
        let thinStore = try ThinAppViewBootstrap.makeStore(config: config, logger: logger, postgresPool: pgPool)
        let router = AppRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          cache: cache,
          logger: logger,
          thinAppViewStore: thinStore
        )
        let app = Application(
          router: router,
          configuration: .init(address: .hostname(listenHost, port: listenPort))
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { await pgPool.run() }
          group.addTask { try await app.run() }
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
}

struct Worker: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Run the thin AppView ingestion worker")

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.worker")
    logger.logLevel = .info
    let workerLogger = logger

    let environment = AppEnvironmentLoader.mergeProcessWithDotenv()
    let config = AppConfig.fromEnvironment(environment)
    guard config.thinAppView.enabled else {
      throw WorkerCommandError.thinAppViewDisabled
    }

    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

    let store: any ThinAppViewStore
    switch config.cacheBackend {
    case .sqlite(let path):
      store = try SQLiteThinAppViewStore(path: path, logger: workerLogger)
    case .postgres(let urlString):
      let pgConfig = try makePostgresConfig(from: urlString, logger: workerLogger)
      let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: workerLogger)
      store = PostgresThinAppViewStore(pool: pgPool, logger: workerLogger)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pgPool.run() }
        group.addTask {
          try await Self.runWorkerLoops(
            store: store,
            config: config,
            httpClient: httpClient,
            logger: workerLogger
          )
        }
        try await group.next()
        group.cancelAll()
      }
      try? await httpClient.shutdown()
      return
    }

    try await Self.runWorkerLoops(
      store: store,
      config: config,
      httpClient: httpClient,
      logger: workerLogger
    )

    try? await httpClient.shutdown()
  }

  private static func runWorkerLoops(
    store: any ThinAppViewStore,
    config: AppConfig,
    httpClient: HTTPClient,
    logger: Logger
  ) async throws {
    let thinConfig = config.thinAppView
    let indexer = ThinAppViewIndexer(store: store, config: thinConfig, logger: logger)
    let firehose = FirehoseSubscriber(
      relayURL: thinConfig.relayWebSocketURL,
      indexer: indexer,
      logger: logger
    )
    let cleanup = ThinAppViewTtlCleanupJob(store: store, config: thinConfig, logger: logger)

    logger.info("Starting thin AppView worker")

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await firehose.runForever() }
      group.addTask { await cleanup.runForever() }
      try await group.next()
      group.cancelAll()
    }
  }
}

enum WorkerCommandError: Error, CustomStringConvertible {
  case thinAppViewDisabled

  var description: String {
    "ENABLE_THIN_APPVIEW must be true to run the worker."
  }
}

private func makePostgresConfig(
  from urlString: String,
  logger: Logger
) throws -> PostgresClient.Configuration {
  guard
    let url = URL(string: urlString),
    let host = url.host,
    !host.isEmpty
  else {
    logger.critical("SUPABASE_DATABASE_URL is not a valid URL", metadata: ["url": .string(urlString)])
    throw PostgresConfigError.invalidURL(urlString)
  }

  let port = url.port ?? 5432
  let username = url.user ?? "postgres"
  let password = url.password
  let database: String? = {
    let raw = String(url.path.drop(while: { $0 == "/" }))
    return raw.isEmpty ? nil : raw
  }()

  var tls = TLSConfiguration.makeClientConfiguration()
  tls.certificateVerification = .none

  return PostgresClient.Configuration(
    host: host,
    port: port,
    username: username,
    password: password,
    database: database,
    tls: .prefer(tls)
  )
}

enum PostgresConfigError: Error {
  case invalidURL(String)
}

extension AppConfig.CacheBackend {
  var description: String {
    switch self {
    case .sqlite(let path): "sqlite(\(path))"
    case .postgres: "postgres(supabase)"
    }
  }
}
