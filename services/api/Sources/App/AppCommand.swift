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

  @Option(name: .long, help: "Port to bind on")
  var port: Int = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080

  @Option(name: .long, help: "Hostname to bind on")
  var hostname: String = "0.0.0.0"

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.api")
    logger.logLevel = .info

    // ── Config ────────────────────────────────────────────────────────────────
    let config = AppConfig.fromEnvironment()

    logger.info(
      "Starting Social Wire API",
      metadata: [
        "env":     .string(config.appEnv.rawValue),
        "backend": .string(config.cacheBackend.description),
        "port":    .string("\(port)"),
      ]
    )

    // ── HTTP client ───────────────────────────────────────────────────────────
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

    // ── Router ────────────────────────────────────────────────────────────────
    let router = Router(context: AppRequestContext.self)
    router.get("/health") { _, _ in ["status": "ok"] }

    let authMiddleware = ATProtoAuthMiddleware(
      httpClient: httpClient,
      plcURL: config.atprotoPLCURL,
      logger: logger
    )
    let protected = router.group().add(middleware: authMiddleware)

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
        let discoveryService = DiscoveryService(
          httpClient: httpClient, cache: cache,
          plcURL: config.atprotoPLCURL, logger: logger
        )
        let contentService = ContentService(
          httpClient: httpClient, cache: cache, logger: logger
        )
        DiscoveryRoutes(discoveryService: discoveryService).register(on: protected)
        ContentRoutes(contentService: contentService).register(on: protected)

        let app = Application(
          router: router,
          configuration: .init(address: .hostname(hostname, port: port))
        )
        try await app.run()

      case .postgres(let urlString):
        // ── Dev / prod mode: Postgres (Supabase) ──────────────────────────
        let pgConfig = try makePostgresConfig(from: urlString, logger: logger)
        let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: logger)

        let cache = SupabaseCache(pool: pgPool, logger: logger)
        let discoveryService = DiscoveryService(
          httpClient: httpClient, cache: cache,
          plcURL: config.atprotoPLCURL, logger: logger
        )
        let contentService = ContentService(
          httpClient: httpClient, cache: cache, logger: logger
        )
        DiscoveryRoutes(discoveryService: discoveryService).register(on: protected)
        ContentRoutes(contentService: contentService).register(on: protected)

        let app = Application(
          router: router,
          configuration: .init(address: .hostname(hostname, port: port))
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
