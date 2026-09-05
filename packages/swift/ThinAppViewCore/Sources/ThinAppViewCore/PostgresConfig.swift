import Foundation
import Logging
import NIOSSL
import PostgresNIO

public enum PostgresConfigError: Error {
  case invalidURL(String)
}

public func makePostgresConfig(
  from urlString: String,
  logger: Logger
) throws -> PostgresClient.Configuration {
  guard
    let url = URL(string: urlString),
    let host = url.host,
    !host.isEmpty
  else {
    logger.critical("DATABASE_URL is not a valid URL")
    throw PostgresConfigError.invalidURL("DATABASE_URL")
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

  var config = PostgresClient.Configuration(
    host: host,
    port: port,
    username: username,
    password: password,
    database: database,
    tls: .prefer(tls)
  )

  config.options.maximumConnections = postgresMaximumConnections()
  config.options.additionalStartupParameters = [
    ("application_name", postgresApplicationName(fallback: logger.label))
  ]

  return config
}

func postgresMaximumConnections(
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int {
  // Keep a conservative per-process default so colocated services leave headroom in the
  // Railway Postgres connection budget even when an override is omitted.
  let configured = environment["POSTGRES_MAX_CONNECTIONS"].flatMap(Int.init) ?? 2
  // One connection may hold the V1 authority row fence while the fenced message performs its
  // projection writes through the same shared pool. Fewer than two would deadlock that handoff.
  return max(2, configured)
}

func postgresApplicationName(
  fallback: String,
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
  let supplied = environment["RAILWAY_SERVICE_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
  let source = supplied.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
  // ASCII and a byte-bound label keep pg_stat_activity readable and avoid control characters.
  let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
  let label = String(source.map { allowed.contains($0) ? $0 : "-" }.prefix(63))
  return label.isEmpty ? "thin-appview" : label
}
