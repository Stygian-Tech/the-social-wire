import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("repair racing cache insertion preserves the new cache and advances its bounded page")
  func metadataRepairCacheInsertRace() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-repair-cache-race.tests")
    let pool = PostgresClient(
      configuration: try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger),
      backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let prefix = "!repair-cache-race-\(UUID().uuidString)-"
    let key = prefix + "1"
    let now = Date()
    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title, eligible,
         first_seen_at, last_seen_at, expires_at)
      VALUES (\(key), 'https://example.com/race', 'example.com', 'Example', 'Story', TRUE,
        \(now), \(now), \(now.addingTimeInterval(86_400)))
      """, logger: logger)
    do {
      try await pool.query(
        "UPDATE wire_metadata_repair_cursor SET canonical_key = \(prefix) WHERE singleton", logger: logger)
      let repair = try await pool.withTransaction(logger: logger) { connection in
        var insertingPID: Int32 = 0
        for try await row in try await connection.query("SELECT pg_backend_pid()", logger: logger) {
          insertingPID = try row.decode(Int32.self)
        }
        try await connection.query(
          """
          INSERT INTO wire_link_metadata_cache
            (canonical_key, canonical_url, source, status, title, retry_after)
          VALUES (\(key), 'https://example.com/race', 'open_graph', 'fresh', 'Concurrent metadata',
            \(now.addingTimeInterval(3_600)))
          """, logger: logger)
        let repair = Task { try await store.repairMetadataPage(asOf: now, pageSize: 1) }
        var observedConflict = false
        for _ in 0..<100 {
          let waits = try await pool.query(
            """
            SELECT EXISTS (SELECT 1 FROM pg_stat_activity
              WHERE \(insertingPID) = ANY(pg_blocking_pids(pid)))
            """, logger: logger)
          for try await row in waits { observedConflict = try row.decode(Bool.self) }
          if observedConflict { break }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedConflict, "Repair must reach ON CONFLICT while the other cache insert is uncommitted")
        return repair
      }
      let progress = try await repair.value
      #expect(progress.scanned == 1 && progress.repaired == 0 && !progress.wrapped)
      for try await row in try await pool.query(
        "SELECT source, status, title, retry_after FROM wire_link_metadata_cache WHERE canonical_key = \(key)",
        logger: logger) {
        let value = try row.decode((String, String, String, Date).self)
        #expect(value.0 == "open_graph" && value.1 == "fresh" && value.2 == "Concurrent metadata")
        #expect(abs(value.3.timeIntervalSince(now.addingTimeInterval(3_600))) < 0.001)
      }
      for try await row in try await pool.query(
        "SELECT canonical_key FROM wire_metadata_repair_cursor WHERE singleton", logger: logger) {
        #expect(try row.decode(String.self) == key)
      }
    } catch {
      try? await cleanupMetadataRepairCacheRace(pool: pool, logger: logger, key: key)
      throw error
    }
    try await cleanupMetadataRepairCacheRace(pool: pool, logger: logger, key: key)
  }

  private func cleanupMetadataRepairCacheRace(pool: PostgresClient, logger: Logger, key: String) async throws {
    try await pool.query("DELETE FROM wire_link_metadata_cache WHERE canonical_key = \(key)", logger: logger)
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    try await pool.query("UPDATE wire_metadata_repair_cursor SET canonical_key = '' WHERE singleton", logger: logger)
  }
}
