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
    let config = GatewayServiceConfig.fromEnvironment(environment)
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
    var serverError: Error?
    do {
      switch config.cacheBackend {
      case .sqlite(let path):
        let cache = try SQLiteCache(path: path, logger: logger)
        let router = GatewayRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          cache: cache,
          logger: logger
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
        let router = GatewayRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          cache: cache,
          logger: logger
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
