import Foundation
import Logging
import NIOSSL
import PostgresNIO

enum PostgresWireConfig {
  static func make(from urlString: String, logger: Logger) throws -> PostgresClient.Configuration {
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
    config.options.maximumConnections = 2
    return config
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
