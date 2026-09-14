import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("enrichment diagnostics retain exact counts and do not leak local limits")
  func enrichmentHealthLimitsAndCounts() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "enrichment-health.integration")
    var configuration = try PostgresWireConfig.make(from: url, logger: logger)
    // The service factory clamps its public pool ceiling to two. Override the
    // local fixture explicitly so reuse assertions inspect the same connection.
    configuration.options.maximumConnections = 1
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    let beforeSettings = try await enrichmentHealthSettings(pool: pool, logger: logger)
    let now = Date()
    let before = try #require(try await store.healthSnapshot(asOf: now))
    let key = "health-diagnostic-" + UUID().uuidString
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title, first_seen_at, last_seen_at, expires_at)
      VALUES (\(key), 'https://example.com/health-diagnostic', 'example.com', 'Example', 'Health diagnostic',
        \(now), \(now), \(now.addingTimeInterval(172_800)))
      """, logger: logger)
    do {
      try await pool.query(
        """
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, source, status, retry_after, fresh_until, stale_until)
        VALUES (\(key), 'https://example.com/health-diagnostic', 'open_graph', 'fresh',
          \(now.addingTimeInterval(86_400)), \(now.addingTimeInterval(86_400)), \(now.addingTimeInterval(172_800)))
        """, logger: logger)
      let after = try #require(try await store.healthSnapshot(asOf: now))
      #expect(after.metadataHitCount == before.metadataHitCount + 1)
      #expect(after.metadataStaleCount == before.metadataStaleCount)
      #expect(after.metadataMissCount == before.metadataMissCount)
      #expect(after.metadataFailureCount == before.metadataFailureCount)
      #expect(after.peopleEligibleCount == before.peopleEligibleCount)
      #expect(after.peopleFreshCount == before.peopleFreshCount)
      #expect(try await enrichmentHealthSettings(pool: pool, logger: logger) == beforeSettings)
    } catch {
      _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
  }

  @Test("blocked enrichment diagnostics time out and return a reusable connection")
  func enrichmentHealthLockTimeout() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "enrichment-health-lock.integration")
    var configuration = try PostgresWireConfig.make(from: url, logger: logger)
    // The service factory clamps its public pool ceiling to two. Override the
    // local fixture explicitly so reuse assertions inspect the same connection.
    configuration.options.maximumConnections = 1
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let blockerPool = PostgresClient(
      configuration: try PostgresWireConfig.make(from: url, maximumConnections: 1, logger: logger),
      backgroundLogger: logger)
    let task = Task { await pool.run() }
    let blockerTask = Task { await blockerPool.run() }
    defer { task.cancel(); blockerTask.cancel() }
    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    let beforeSettings = try await enrichmentHealthSettings(pool: pool, logger: logger)
    try await blockerPool.withTransaction(logger: logger) { connection in
      try await connection.query("LOCK TABLE wire_link_metadata_cache IN ACCESS EXCLUSIVE MODE", logger: logger)
      do {
        _ = try await store.healthSnapshot(asOf: Date())
        Issue.record("A blocked diagnostic must not ignore its local lock timeout")
      } catch let error as PostgresTransactionError {
        let cause = try #require(error.closureError as? PSQLError)
        #expect(cause.serverInfo?[.sqlState] == "55P03")
        #expect(error.rollbackError == nil)
      }
    }
    #expect(try await enrichmentHealthSettings(pool: pool, logger: logger) == beforeSettings)
    #expect(try await store.healthSnapshot(asOf: Date()) != nil)
  }
}

private func enrichmentHealthSettings(pool: PostgresClient, logger: Logger) async throws -> [String] {
  let rows = try await pool.query(
    "SELECT current_setting('statement_timeout'), current_setting('lock_timeout'), current_setting('transaction_read_only')",
    logger: logger)
  for try await row in rows {
    let settings = try row.decode((String, String, String).self)
    return [settings.0, settings.1, settings.2]
  }
  return []
}
