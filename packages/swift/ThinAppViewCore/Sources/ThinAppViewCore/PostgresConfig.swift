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

  var config = PostgresClient.Configuration(
    host: host,
    port: port,
    username: username,
    password: password,
    database: database,
    tls: .prefer(tls)
  )

  // Supabase session pooler caps concurrent clients (often 15 shared across services).
  // PostgresNIO defaults to 20 — stay under the pool limit via POSTGRES_MAX_CONNECTIONS.
  let maxConnections =
    ProcessInfo.processInfo.environment["POSTGRES_MAX_CONNECTIONS"].flatMap(Int.init) ?? 8
  config.options.maximumConnections = max(1, maxConnections)

  return config
}
