// AppCommand.swift — program entry point for the HTTP API server.

import ArgumentParser
import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import PostgresNIO
import ThinAppViewCore

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct App: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The Social Wire API Service",
    subcommands: [Serve.self],
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

    logger.warning(
      "services/api is a compatibility shim; deploy services/gateway and services/appview instead"
    )
    logger.info(
      "Starting Social Wire API (deprecated monolith shim)",
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

extension AppConfig.CacheBackend {
  var description: String {
    switch self {
    case .sqlite(let path): "sqlite(\(path))"
    case .postgres: "postgres(supabase)"
    }
  }
}
