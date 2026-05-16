// AppCommand.swift — program entry point.
//
// Uses @main so that ArgumentParser can dispatch the async `run()` method
// correctly. A file named main.swift cannot use @main (Swift treats it as the
// implicit top-level code file), so the struct lives here instead.

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
    abstract: "The Social Wire API Service"
  )

  @Option(name: .long, help: "Port to bind on (overrides PORT from environment / .env)")
  var port: Int?

  @Option(name: .long, help: "Hostname to bind on (overrides BIND_HOST from environment / .env)")
  var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.api")
    logger.logLevel = .info

    // ── Config ────────────────────────────────────────────────────────────────
    let environment = AppEnvironmentLoader.mergeProcessWithDotenv()
    let config = AppConfig.fromEnvironment(environment)

    let listenPort = port ?? Int(environment["PORT"] ?? "8080") ?? 8080
    let listenHost = hostname ?? environment["BIND_HOST"] ?? "0.0.0.0"

    logger.info(
      "Starting Social Wire API",
      metadata: [
        "env":     .string(config.appEnv.rawValue),
        "backend": .string(config.cacheBackend.description),
        "legacy_content_api_enabled": .string(config.enableLegacyContentAPI ? "true" : "false"),
        "port":    .string("\(listenPort)"),
      ]
    )

    // ── HTTP client ───────────────────────────────────────────────────────────
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

    // ── App bootstrap — branching on cache backend ────────────────────────────
    //
    // Swift has no async defer, so we capture any thrown error, shut the HTTP
    // client down (which must happen before it deinits), and rethrow afterwards.
    // This guarantees cleanup whether the server exits normally or via Ctrl+C.
    var serverError: Error?
    do {
      switch config.cacheBackend {

      case .sqlite(let path):
        // ── Local mode: SQLite, no Postgres pool ────────────────────────────
        let cache = try SQLiteCache(path: path, logger: logger)
        let router = AppRouterBuilder.router(
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
        // ── Dev / prod mode: Postgres (Supabase) ──────────────────────────
        let pgConfig = try makePostgresConfig(from: urlString, logger: logger)
        let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: logger)

        let cache = SupabaseCache(pool: pgPool, logger: logger)
        let router = AppRouterBuilder.router(
          config: config,
          httpClient: httpClient,
          cache: cache,
          logger: logger
        )

        let app = Application(
          router: router,
          configuration: .init(address: .hostname(listenHost, port: listenPort))
        )

        // Run the Postgres pool and HTTP server together; cancel both on exit.
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

    // Always shut the HTTP client down before it deinits.
    try? await httpClient.shutdown()

    if let serverError { throw serverError }
  }
}

// ── Postgres URL parser ───────────────────────────────────────────────────────

/// Parses a `postgresql://user:pass@host:port/db` URL into a `PostgresClient.Configuration`.
///
/// Uses opportunistic TLS (`.prefer`) which works with Supabase and most managed
/// Postgres providers. Certificate verification is disabled to support Supabase's
/// pooler endpoint; re-enable it for strict production hardening.
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

  let port     = url.port ?? 5432
  let username = url.user ?? "postgres"
  let password = url.password
  let database: String? = {
    let raw = String(url.path.drop(while: { $0 == "/" }))
    return raw.isEmpty ? nil : raw
  }()

  // Opportunistic TLS upgrade; certificate verification disabled for Supabase pooler compat.
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

// ── Helpers ───────────────────────────────────────────────────────────────────

extension AppConfig.CacheBackend {
  var description: String {
    switch self {
    case .sqlite(let path): "sqlite(\(path))"
    case .postgres:         "postgres(supabase)"
    }
  }
}
