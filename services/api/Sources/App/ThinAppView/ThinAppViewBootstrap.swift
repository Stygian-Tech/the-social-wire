import Foundation
import Logging
import PostgresNIO

enum ThinAppViewBootstrap {
  static func makeStore(config: AppConfig, logger: Logger, postgresPool: PostgresClient?) throws -> (any ThinAppViewStore)? {
    let thinConfig = ThinAppViewConfig.fromEnvironment()
    guard thinConfig.enabled else { return nil }

    switch config.cacheBackend {
    case .sqlite(let path):
      return try SQLiteThinAppViewStore(path: path, logger: logger)
    case .postgres:
      guard let postgresPool else {
        throw ThinAppViewBootstrapError.missingPostgresPool
      }
      return PostgresThinAppViewStore(pool: postgresPool, logger: logger)
    }
  }
}

enum ThinAppViewBootstrapError: Error, CustomStringConvertible {
  case missingPostgresPool

  var description: String {
    switch self {
    case .missingPostgresPool:
      "Thin AppView requires a Postgres pool when APP_ENV is dev/prod."
    }
  }
}
