import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("scheduling projection is opt-in, backfills exactly and preserves locked priority order")
  func schedulingProjectionParityAndClaims() async throws {
    try await withSchedulingDatabase { pool, logger in
      let now = Date()
      let prefix = "schedule-parity-\(UUID().uuidString)-"
      let keys = (0..<8).map { prefix + String($0) }
      do {
        for (index, key) in keys.enumerated() {
          try await insertSchedulingItem(pool, logger, key: key, now: now)
          try await pool.query("""
            UPDATE wire_items SET last_signal_at = \(index < 5 ? now : nil),
              language_code = \(index == 7 ? "en" : "und") WHERE canonical_key = \(key)
            """, logger: logger)
          try await pool.query("""
            INSERT INTO wire_link_metadata_cache (canonical_key, canonical_url, source, status, retry_after)
            VALUES (\(key), \("https://example.com/" + key), 'fallback', 'pending',
              \(now.addingTimeInterval(index == 6 ? 3600 : -Double(index + 1))))
            """, logger: logger)
        }
        let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger, schedulingReadEnabled: true)
        #expect(try await store.metadataSchedulingReady() == false)
        let disabled = try await pool.query("SELECT COUNT(*)::bigint FROM wire_metadata_priority_work", logger: logger)
        for try await row in disabled { #expect(try row.decode(Int64.self) == 0) }
        try await pool.query("SELECT wire_metadata_schedule_set_tracking(true)", logger: logger)
        try await store.backfillMetadataScheduling(pageSize: 3)
        for _ in 0..<100 {
          try await store.backfillMetadataScheduling(pageSize: 500)
          _ = try await store.validateMetadataSchedulingIfComplete(asOf: now)
          if try await store.metadataSchedulingReady() { break }
        }
        #expect(try await store.metadataSchedulingReady())
        let old = try await schedulingClaimKeys(pool, logger, now: now, scheduling: false)
        let new = try await schedulingClaimKeys(pool, logger, now: now, scheduling: true)
        #expect(old == new)
        #expect(new == Set([keys[4], keys[3], keys[2]]))
        try await pool.withTransaction(logger: logger) { locked in
          try await locked.query("SELECT canonical_key FROM wire_link_metadata_cache WHERE canonical_key = \(keys[4]) FOR UPDATE", logger: logger)
          let oldLocked = try await schedulingClaimKeys(pool, logger, now: now, scheduling: false)
          let newLocked = try await schedulingClaimKeys(pool, logger, now: now, scheduling: true)
          #expect(oldLocked == newLocked)
          #expect(newLocked == Set([keys[3], keys[2], keys[1]]))
        }
        // Even a deliberately corrupted projection cannot bypass authoritative
        // item eligibility. Cache/lease rechecks alone would not reject this row.
        try await pool.query("UPDATE wire_items SET eligible = false WHERE canonical_key = \(keys[4])", logger: logger)
        try await pool.query("UPDATE wire_metadata_priority_work SET eligible = true WHERE canonical_key = \(keys[4])", logger: logger)
        let rechecked = try await schedulingClaimKeys(pool, logger, now: now, scheduling: true)
        #expect(!rechecked.contains(keys[4]))
        try await pool.query("DELETE FROM wire_items WHERE canonical_key = ANY(\(keys))", logger: logger)
        try await store.cleanupMetadataScheduling()
        let removed = try await pool.query("SELECT COUNT(*)::bigint FROM wire_metadata_priority_work WHERE canonical_key = ANY(\(keys))", logger: logger)
        for try await row in removed { #expect(try row.decode(Int64.self) == 0) }
        try await pool.query("""
          UPDATE wire_metadata_schedule_control
          SET validated_postmaster_started_at = pg_postmaster_start_time() - INTERVAL '1 second',
              tracking_postmaster_started_at = pg_postmaster_start_time() - INTERVAL '1 second'
          """, logger: logger)
        #expect(try await store.metadataSchedulingReady() == false)
        try await store.backfillMetadataScheduling()
        let reset = try await pool.query("SELECT read_ready FROM wire_metadata_schedule_control", logger: logger)
        for try await row in reset { #expect(try row.decode(Bool.self) == false) }
      } catch {
        _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key = ANY(\(keys))", logger: logger)
        throw error
      }
    }
  }

  @Test("independent concurrent source updates merge without overwriting either field group")
  func schedulingProjectionConcurrentUpdates() async throws {
    try await withSchedulingDatabase { pool, logger in
      let now = Date()
      let key = "schedule-concurrent-\(UUID().uuidString)"
      try await insertSchedulingItem(pool, logger, key: key, now: now)
      try await pool.query("""
        INSERT INTO wire_link_metadata_cache (canonical_key, canonical_url, source, status, retry_after)
        VALUES (\(key), \("https://example.com/" + key), 'fallback', 'pending', \(now))
        """, logger: logger)
      do {
        try await pool.query("SELECT wire_metadata_schedule_set_tracking(true)", logger: logger)
        // Neither field group exists initially: simultaneous updates each create
        // a placeholder, and the PK conflict merges only the arriving group.
        async let itemWrite: () = schedulingUpdateItem(pool, logger, key: key, at: now.addingTimeInterval(10))
        async let cacheWrite: () = schedulingUpdateCache(pool, logger, key: key, at: now.addingTimeInterval(20))
        _ = try await (itemWrite, cacheWrite)
        let rows = try await pool.query("""
          SELECT item_present, cache_present, last_signal_at, retry_after
          FROM wire_metadata_priority_work WHERE canonical_key = \(key)
          """, logger: logger)
        var found = false
        for try await row in rows {
          let value = try row.decode((Bool, Bool, Date, Date).self)
          #expect(value.0 && value.1)
          #expect(abs(value.2.timeIntervalSince(now.addingTimeInterval(10))) < 0.00001)
          #expect(abs(value.3.timeIntervalSince(now.addingTimeInterval(20))) < 0.00001)
          found = true
        }
        #expect(found)
        // Clearing the cache group retains all item fields; inserting the cache
        // again restores only cache fields. Metadata does not erase observations.
        try await pool.query("DELETE FROM wire_link_metadata_cache WHERE canonical_key = \(key)", logger: logger)
        let absent = try await pool.query("SELECT item_present, cache_present, retry_after IS NULL FROM wire_metadata_priority_work WHERE canonical_key = \(key)", logger: logger)
        for try await row in absent {
          let value = try row.decode((Bool, Bool, Bool).self)
          #expect(value.0 && !value.1 && value.2)
        }
        try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
        let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
        try await store.cleanupMetadataScheduling()
      } catch {
        _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
        throw error
      }
    }
  }

  @Test("disabled epochs reset readiness and rolled back source changes leave no projection")
  func schedulingProjectionEpochAndRollback() async throws {
    try await withSchedulingDatabase { pool, logger in
      let now = Date()
      let key = "schedule-rollback-\(UUID().uuidString)"
      try await pool.query("SELECT wire_metadata_schedule_set_tracking(true)", logger: logger)
      do {
        try await pool.withTransaction(logger: logger) { connection in
          try await connection.query("""
            INSERT INTO wire_items (canonical_key, canonical_url, source_domain, source_name, title,
              first_seen_at, last_seen_at, expires_at)
            VALUES (\(key), \("https://example.com/" + key), 'example.com', 'Example', 'Story',
              \(now), \(now), \(now.addingTimeInterval(86400)))
            """, logger: logger)
          throw SchedulingRollback.expected
        }
      } catch let error as PostgresTransactionError where error.closureError is SchedulingRollback
        && error.rollbackError == nil && error.commitError == nil {}
      let count = try await pool.query("SELECT COUNT(*)::bigint FROM wire_metadata_priority_work WHERE canonical_key = \(key)", logger: logger)
      for try await row in count { #expect(try row.decode(Int64.self) == 0) }
      try await pool.query("UPDATE wire_metadata_schedule_control SET read_ready = true", logger: logger)
      try await pool.query("SELECT wire_metadata_schedule_set_tracking(false)", logger: logger)
      let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
      #expect(try await store.metadataSchedulingReady() == false)
      try await pool.query("SELECT wire_metadata_schedule_set_tracking(true)", logger: logger)
      #expect(try await store.metadataSchedulingReady() == false)
    }
  }
}

private enum SchedulingRollback: Error { case expected }

private func withSchedulingDatabase(_ operation: @Sendable (PostgresClient, Logger) async throws -> Void) async throws {
  guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
  let logger = Logger(label: "metadata-scheduling.integration")
  let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 6, logger: logger)
  let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
  let task = Task { await pool.run() }
  defer { task.cancel() }
  try await pool.query("SELECT wire_metadata_schedule_set_tracking(false)", logger: logger)
  do { try await operation(pool, logger) }
  catch {
    logger.error("Scheduling fixture failed", metadata: ["error": .string(String(reflecting: error))])
    _ = try? await pool.query("SELECT wire_metadata_schedule_set_tracking(false)", logger: logger)
    throw error
  }
  try await pool.query("SELECT wire_metadata_schedule_set_tracking(false)", logger: logger)
  try await pool.query("TRUNCATE wire_metadata_priority_work", logger: logger)
}

private func insertSchedulingItem(_ pool: PostgresClient, _ logger: Logger, key: String, now: Date) async throws {
  try await pool.query("""
    INSERT INTO wire_items (canonical_key, canonical_url, source_domain, source_name, title,
      language_code, eligible, target_kind, commercial_class, source_confidence,
      first_seen_at, last_seen_at, expires_at)
    VALUES (\(key), \("https://example.com/" + key), 'example.com', 'Example', 'Story',
      'und', true, 'external_article', 'normal', 0.8, \(now), \(now), \(now.addingTimeInterval(86400)))
    """, logger: logger)
}

private func schedulingUpdateItem(_ pool: PostgresClient, _ logger: Logger, key: String, at: Date) async throws {
  try await pool.query("UPDATE wire_items SET last_signal_at = \(at) WHERE canonical_key = \(key)", logger: logger)
}

private func schedulingUpdateCache(_ pool: PostgresClient, _ logger: Logger, key: String, at: Date) async throws {
  try await pool.query("UPDATE wire_link_metadata_cache SET retry_after = \(at) WHERE canonical_key = \(key)", logger: logger)
}

private func schedulingClaimKeys(_ pool: PostgresClient, _ logger: Logger, now: Date, scheduling: Bool) async throws -> Set<String> {
  try await pool.withConnection { connection in
    try await connection.query("BEGIN", logger: logger)
    do {
      let rows = try await connection.query(PostgresWireLinkMetadataStore.metadataPriorityClaimQuery(asOf: now, limit: 3, scheduling: scheduling), logger: logger)
      var keys = Set<String>()
      for try await row in rows { keys.insert(try row.makeRandomAccess()["canonical_key"].decode(String.self)) }
      try await connection.query("ROLLBACK", logger: logger)
      return keys
    } catch {
      _ = try? await connection.query("ROLLBACK", logger: logger)
      throw error
    }
  }
}
