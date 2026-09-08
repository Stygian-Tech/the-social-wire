import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("indexed general metadata claims skip locks and future work while preserving backfill")
  func metadataGeneralClaimEligibilityAndLocks() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-work-index.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let prefix = "metadata-index-\(UUID().uuidString.lowercased())-"
    let now = Date()
    let names = ["locked", "due", "future", "fresh", "backfill", "checked"]
    do {
      for name in names {
        let key = prefix + name
        // Known language keeps these rows on the general lane, not the separate
        // recent unclassified-story priority lane.
        try await pool.query(
          """
          INSERT INTO wire_items
            (canonical_key, canonical_url, source_domain, source_name, title,
             language_code, first_seen_at, last_seen_at, expires_at)
          VALUES (\(key), \("https://example.com/" + key), 'example.com', 'Example',
                  'Metadata index fixture', 'en', \(now), \(now), \(now.addingTimeInterval(86_400)))
          """, logger: logger)
        let futureRetry = name == "future" || name == "backfill"
        let fresh = name == "fresh" || name == "backfill"
        let checked: Date? = name == "checked" || name == "fresh"
          ? now.addingTimeInterval(-86_400) : nil
        let freshUntil: Date? = fresh ? now.addingTimeInterval(86_400) : nil
        try await pool.query(
          """
          INSERT INTO wire_link_metadata_cache
            (canonical_key, canonical_url, source, status, retry_after, fresh_until, language_checked_at)
          VALUES (\(key), \("https://example.com/" + key),
                  \(name == "backfill" ? "open_graph" : "embedded_card"),
                  \(fresh ? "fresh" : "pending"),
                  \(now.addingTimeInterval(futureRetry ? 3_600 : -60)), \(freshUntil), \(checked))
          """, logger: logger)
      }
      let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
      try await pool.withTransaction(logger: logger) { connection in
        try await connection.query(
          "SELECT canonical_key FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "locked") FOR UPDATE",
          logger: logger)
        // Other serialized integration fixtures can leave unrelated corpus
        // rows. Assert only our fixture, without assuming UPDATE RETURNING order.
        let targets = try await store.claimDue(limit: 250, asOf: now)
        let claimed = Set(targets.map(\.canonicalKey).filter { $0.hasPrefix(prefix) })
        #expect(claimed == Set(["due", "backfill", "checked"].map { prefix + $0 }))
      }
      let unlocked = try await store.claimDue(limit: 250, asOf: now)
      #expect(unlocked.map(\.canonicalKey).filter { $0.hasPrefix(prefix) } == [prefix + "locked"])
    } catch {
      _ = try? await pool.query(
        "DELETE FROM wire_items WHERE canonical_key = ANY(\(names.map { prefix + $0 }))", logger: logger)
      throw error
    }
    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key = ANY(\(names.map { prefix + $0 }))", logger: logger)
  }
}
