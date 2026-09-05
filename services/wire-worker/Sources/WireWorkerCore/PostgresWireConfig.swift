import Foundation
import Logging
import NIOSSL
import PostgresNIO

enum PostgresWireConfig {
  static func make(
    from urlString: String,
    maximumConnections: Int = 2,
    environment: [String: String] = [:],
    logger: Logger
  ) throws -> PostgresClient.Configuration {
    guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
      logger.critical("DATABASE_URL is not a valid URL")
      throw WireWorkerConfigError.missingDatabaseURL
    }
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .none
    var config = PostgresClient.Configuration(
      host: host,
      port: url.port ?? 5432,
      username: url.user ?? "postgres",
      password: url.password,
      database: String(url.path.drop(while: { $0 == "/" })).nilIfEmpty,
      tls: .prefer(tls)
    )
    config.options.maximumConnections = max(2, min(maximumConnections, 64))
    config.options.additionalStartupParameters = [
      ("application_name", applicationName(environment: environment, fallback: logger.label))
    ]
    return config
  }

  private static func applicationName(environment: [String: String], fallback: String) -> String {
    let supplied = environment["RAILWAY_SERVICE_NAME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let source = supplied.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    // Match the shared database config: ASCII labels stay readable in pg_stat_activity,
    // exclude control characters, and fit PostgreSQL's 63-byte application-name limit.
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    let label = String(source.map { allowed.contains($0) ? $0 : "-" }.prefix(63))
    return label.isEmpty ? "wire-worker" : label
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
