import Foundation

/// Configuration loaded from environment variables at startup.
struct AppConfig: Sendable {
  let atprotoPLCURL: String
  let appEnv: AppEnvironment
  let cacheBackend: CacheBackend

  enum AppEnvironment: String, Sendable {
    case local
    case dev
    case prod
  }

  enum CacheBackend: Sendable {
    /// SQLite file on disk. Used automatically when APP_ENV=local.
    case sqlite(path: String)
    /// Postgres (Supabase). Used for dev and prod.
    case postgres(url: String)
  }

  /// Loads configuration from environment variables.
  ///
  /// - Parameter env: Override the environment dictionary (default: the process
  ///   environment). Pass a custom dictionary in unit tests to avoid mutating
  ///   `ProcessInfo.processInfo.environment`.
  static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> AppConfig {
    let appEnv = AppEnvironment(rawValue: env["APP_ENV"] ?? "local") ?? .local
    let plcURL = env["ATPROTO_PLC_URL"] ?? "https://plc.directory"

    let backend: CacheBackend
    switch appEnv {
    case .local:
      // Default path is ./social-wire.sqlite in the working directory.
      let sqlitePath = env["SQLITE_DB_PATH"] ?? "./social-wire.sqlite"
      backend = .sqlite(path: sqlitePath)

    case .dev, .prod:
      guard let dbURL = env["SUPABASE_DATABASE_URL"], !dbURL.isEmpty else {
        fatalError("SUPABASE_DATABASE_URL is required for APP_ENV=\(appEnv.rawValue)")
      }
      backend = .postgres(url: dbURL)
    }

    return AppConfig(
      atprotoPLCURL: plcURL,
      appEnv: appEnv,
      cacheBackend: backend
    )
  }
}
