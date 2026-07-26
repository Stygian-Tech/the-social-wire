import Foundation

/// SQLite or Postgres database backend for Thin AppView persistence.
public enum DatabaseBackend: Sendable {
  case sqlite(path: String)
  case postgres(url: String)

  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> DatabaseBackend {
    let configuredEnvironment = env["APP_ENV"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let appEnv = configuredEnvironment, !appEnv.isEmpty else {
      throw DatabaseBackendConfigurationError.missingAppEnvironment
    }
    guard ["local", "dev", "prod"].contains(appEnv) else {
      throw DatabaseBackendConfigurationError.invalidAppEnvironment(appEnv)
    }
    switch appEnv {
    case "local":
      return .sqlite(path: env["SQLITE_DB_PATH"] ?? "./social-wire.sqlite")

    default:
      guard let dbURL = env["SUPABASE_DATABASE_URL"], !dbURL.isEmpty else {
        throw DatabaseBackendConfigurationError.missingDatabaseURL(environment: appEnv)
      }
      return .postgres(url: dbURL)
    }
  }
}

public enum DatabaseBackendConfigurationError: Error, Equatable, CustomStringConvertible {
  case missingAppEnvironment
  case invalidAppEnvironment(String)
  case missingDatabaseURL(environment: String)

  public var description: String {
    switch self {
    case .missingAppEnvironment:
      return "APP_ENV is required and must be local, dev, or prod."
    case .invalidAppEnvironment(let value):
      return "APP_ENV must be local, dev, or prod (received \(value))."
    case .missingDatabaseURL(let environment):
      return "SUPABASE_DATABASE_URL is required for APP_ENV=\(environment)."
    }
  }
}
