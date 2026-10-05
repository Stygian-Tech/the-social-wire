import Foundation
import Logging
import PostgresNIO
import SportsCore

struct PostgresSportsCatalogReader {
  static func load(pool: PostgresClient, logger: Logger) async throws -> SportsProjectionCatalog? {
    let rows = try await pool.query("SELECT payload::text FROM sports_catalog_snapshots WHERE is_active=TRUE LIMIT 1", logger: logger)
    for try await row in rows {
      return .init(snapshot: try JSONDecoder().decode(SportsCatalogSnapshot.self, from: Data(try row.decode(String.self).utf8)))
    }
    return nil
  }
}
