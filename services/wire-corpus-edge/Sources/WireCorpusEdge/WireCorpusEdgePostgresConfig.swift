import Foundation
import Logging
import NIOSSL
import PostgresNIO

enum WireCorpusEdgePostgresConfig {
  static func make(
    from urlString: String,
    maximumConnections: Int,
    logger: Logger
  ) throws -> PostgresClient.Configuration {
    guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
      logger.critical("The Wire Corpus Edge DATABASE_URL is invalid")
      throw WireCorpusEdgeConfigError.missingDatabaseURL
    }
    var tls = TLSConfiguration.makeClientConfiguration()
    // The edge connects to PostgreSQL only over its Production private network. Railway's
    // internal database hostname is protected by the environment WireGuard boundary.
    tls.certificateVerification = .none
    var configuration = PostgresClient.Configuration(
      host: host,
      port: url.port ?? 5432,
      username: url.user ?? "postgres",
      password: url.password,
      database: String(url.path.drop(while: { $0 == "/" })).nilIfEmpty,
      tls: .prefer(tls)
    )
    configuration.options.maximumConnections = maximumConnections
    return configuration
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
