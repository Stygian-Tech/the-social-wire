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
    logger.critical("DATABASE_URL is not a valid URL", metadata: ["url": .string(urlString)])
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

  config.options.maximumConnections = postgresMaximumConnections()

  return config
}

func postgresMaximumConnections(
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int {
  // Keep a conservative per-process default so colocated services leave headroom in the
  // Railway Postgres connection budget even when an override is omitted.
  let configured = environment["POSTGRES_MAX_CONNECTIONS"].flatMap(Int.init) ?? 2
  return max(1, configured)
}
