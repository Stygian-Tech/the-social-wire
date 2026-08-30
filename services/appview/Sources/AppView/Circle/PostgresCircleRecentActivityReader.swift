import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresCircleRecentActivityReader: CircleRecentActivityReading {
  private let pool: PostgresClient
  private let actorHasher: WireActorHasher
  private let logger: Logger

  init(pool: PostgresClient, actorHasher: WireActorHasher, logger: Logger) {
    self.pool = pool
    self.actorHasher = actorHasher
    self.logger = logger
  }

  func mostRecentActivity(for actorDIDs: Set<String>) async throws -> [String: Date] {
    guard !actorDIDs.isEmpty else { return [:] }
    var didByHash: [String: String] = [:]
    for did in actorDIDs {
      didByHash[try actorHasher.hash(did)] = did
    }
    let hashes = Array(didByHash.keys)
    let since = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    let rows = try await pool.query(
      """
      SELECT actor_key_hash, MAX(occurred_at)
      FROM wire_signal_events
      WHERE actor_key_hash = ANY(\(hashes)) AND occurred_at >= \(since)
      GROUP BY actor_key_hash
      """,
      logger: logger
    )
    var result: [String: Date] = [:]
    for try await row in rows {
      let value = try row.decode((String, Date).self)
      if let did = didByHash[value.0] { result[did] = value.1 }
    }
    return result
  }
}
