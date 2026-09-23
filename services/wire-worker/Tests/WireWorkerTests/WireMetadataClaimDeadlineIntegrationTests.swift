import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("priority lock timeout falls back and leases eligible general work")
  func metadataPriorityDeadlineFallback() async throws {
    try await runDeadlineFixture { fixture in
      let key = try await seedDeadlineMetadata(fixture)
      let store = PostgresWireLinkMetadataStore(pool: fixture.pool, logger: fixture.logger)
      try await fixture.pool.withTransaction(logger: fixture.logger) { blocker in
        try await blocker.query("LOCK TABLE wire_items IN ACCESS EXCLUSIVE MODE", logger: fixture.logger)
        let started = ContinuousClock.now
        let targets = try await isolatedDeadlineClaim(fixture, store: store, limit: 1, asOf: fixture.now)
        #expect(started.duration(to: .now) < .seconds(4))
        #expect(targets.contains { $0.canonicalKey == key })
        #expect(targets.first?.leaseExpiresAt == fixture.now.addingTimeInterval(300))
        #expect(await store.priorityClaimPacing.begin() == false)
      }
      // The transaction-local settings must not poison subsequent pooled work.
      try await fixture.pool.withConnection { connection in
        let rows = try await connection.query("SELECT current_setting('statement_timeout'), current_setting('lock_timeout')", logger: fixture.logger)
        for try await row in rows {
          let settings = try row.decode((String, String).self)
          #expect(settings.0 == "0")
          #expect(settings.1 == "0")
        }
      }
    }
  }

  @Test("scheduling readiness and claims share the only available pool connection")
  func metadataClaimSchedulingConnection() async throws {
    try await runDeadlineFixture { fixture in
      let key = try await seedDeadlineMetadata(fixture)
      let store = PostgresWireLinkMetadataStore(pool: fixture.pool, logger: fixture.logger, schedulingReadEnabled: true)
      try await fixture.pool.withConnection { _ in
        let targets = try await isolatedDeadlineClaim(fixture, store: store, limit: 1, asOf: fixture.now)
        #expect(targets.contains { $0.canonicalKey == key })
      }
    }
  }

  @Test("readiness lock timeout remains bounded and leaves metadata unleased")
  func metadataReadinessDeadline() async throws {
    try await runDeadlineFixture { fixture in
      let key = try await seedDeadlineMetadata(fixture)
      let store = PostgresWireLinkMetadataStore(pool: fixture.pool, logger: fixture.logger, schedulingReadEnabled: true)
      try await fixture.pool.withTransaction(logger: fixture.logger) { blocker in
        try await blocker.query("LOCK TABLE wire_metadata_schedule_control IN ACCESS EXCLUSIVE MODE", logger: fixture.logger)
        await #expect(throws: (any Error).self) { _ = try await isolatedDeadlineClaim(fixture, store: store, limit: 1, asOf: fixture.now) }
      }
      try await assertDeadlineMetadataPending(fixture, key: key)
    }
  }

  @Test("cancelling a blocked priority claim rolls back instead of falling through")
  func metadataClaimCancellation() async throws {
    try await runDeadlineFixture(maximumConnections: 4) { fixture in
      let key = try await seedDeadlineMetadata(fixture)
      let store = PostgresWireLinkMetadataStore(pool: fixture.pool, logger: fixture.logger)
      try await fixture.pool.withTransaction(logger: fixture.logger) { blocker in
        try await blocker.query("LOCK TABLE wire_items IN ACCESS EXCLUSIVE MODE", logger: fixture.logger)
        let claim = Task { try await isolatedDeadlineClaim(fixture, store: store, limit: 1, asOf: fixture.now) }
        // Observe the actual blocked query before cancelling; no timing-only race.
        var blocked = false
        for _ in 0..<100 {
          let rows = try await fixture.pool.query("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE 'WITH due%' AND query LIKE '%wire_items%')", logger: fixture.logger)
          for try await row in rows { blocked = try row.decode(Bool.self) }
          if blocked { break }
          try await Task.sleep(for: .milliseconds(2))
        }
        claim.cancel()
        await #expect(throws: (any Error).self) { _ = try await claim.value }
        #expect(blocked)
      }
      try await assertDeadlineMetadataPending(fixture, key: key)
    }
  }

  @Test("general timeout rolls back an already successful priority lease")
  func metadataGeneralTimeoutRollsBackPriority() async throws {
    try await runDeadlineFixture { fixture in
      let priority = try await seedDeadlineMetadata(fixture)
      let general = try await fixture.item("general")
      try await fixture.pool.query("UPDATE wire_items SET language_code = 'und', eligible = true, target_kind = 'external_article', commercial_class = 'normal', source_confidence = 1, last_signal_at = \(fixture.now.addingTimeInterval(86400)) WHERE canonical_key = \(priority)", logger: fixture.logger)
      try await fixture.pool.query("INSERT INTO wire_link_metadata_cache (canonical_key, canonical_url, status, retry_after) VALUES (\(general), 'https://example.com/general', 'pending', \(Date(timeIntervalSince1970: 0)))", logger: fixture.logger)
      // A test-only trigger forces a real server statement deadline after the
      // priority UPDATE succeeded. Names and key contain only fixture UUID text.
      let name = "claim_deadline_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      try await fixture.pool.query(PostgresQuery(unsafeSQL: "CREATE FUNCTION \(name)() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(3); RETURN NEW; END $$"), logger: fixture.logger)
      do {
        try await fixture.pool.query(PostgresQuery(unsafeSQL: "CREATE TRIGGER \(name) BEFORE UPDATE ON wire_link_metadata_cache FOR EACH ROW WHEN (OLD.canonical_key = '\(general)') EXECUTE FUNCTION \(name)()"), logger: fixture.logger)
        let store = PostgresWireLinkMetadataStore(pool: fixture.pool, logger: fixture.logger)
        await #expect(throws: (any Error).self) { _ = try await isolatedDeadlineClaim(fixture, store: store, limit: 2, asOf: fixture.now) }
        try await assertDeadlineMetadataPending(fixture, key: priority)
        try await assertDeadlineMetadataPending(fixture, key: general)
      } catch {
        try await fixture.pool.query(PostgresQuery(unsafeSQL: "DROP FUNCTION \(name)() CASCADE"), logger: fixture.logger)
        throw error
      }
      try await fixture.pool.query(PostgresQuery(unsafeSQL: "DROP FUNCTION \(name)() CASCADE"), logger: fixture.logger)
    }
  }

  @Test("priority statement timeout rolls back its savepoint and general work progresses")
  func metadataPriorityStatementTimeoutFallback() async throws {
    try await runDeadlineFixture { fixture in
      let key = try await seedDeadlineMetadata(fixture)
      try await fixture.pool.query("UPDATE wire_items SET language_code = 'und', eligible = true, target_kind = 'external_article', commercial_class = 'normal', source_confidence = 1, last_signal_at = \(fixture.now.addingTimeInterval(86400)) WHERE canonical_key = \(key)", logger: fixture.logger)
      let name = "claim_deadline_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      try await fixture.pool.query(PostgresQuery(unsafeSQL: "CREATE FUNCTION \(name)() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF current_query() LIKE '%JOIN wire_link_metadata_cache%' THEN PERFORM pg_sleep(3); END IF; RETURN NEW; END $$"), logger: fixture.logger)
      do {
        try await fixture.pool.query(PostgresQuery(unsafeSQL: "CREATE TRIGGER \(name) BEFORE UPDATE ON wire_link_metadata_cache FOR EACH ROW WHEN (OLD.canonical_key = '\(key)') EXECUTE FUNCTION \(name)()"), logger: fixture.logger)
        let store = PostgresWireLinkMetadataStore(pool: fixture.pool, logger: fixture.logger)
        let targets = try await isolatedDeadlineClaim(fixture, store: store, limit: 1, asOf: fixture.now)
        #expect(targets.map(\.canonicalKey) == [key])
        #expect(targets.first?.leaseExpiresAt == fixture.now.addingTimeInterval(300))
        #expect(await store.priorityClaimPacing.begin() == false)
      } catch {
        try await fixture.pool.query(PostgresQuery(unsafeSQL: "DROP FUNCTION \(name)() CASCADE"), logger: fixture.logger)
        throw error
      }
      try await fixture.pool.query(PostgresQuery(unsafeSQL: "DROP FUNCTION \(name)() CASCADE"), logger: fixture.logger)
    }
  }

  private func runDeadlineFixture(
    maximumConnections: Int = 2,
    _ operation: (WireRollupIntegrationFixture) async throws -> Void
  ) async throws {
    try await WireRollupIntegrationFixture.run(maximumConnections: maximumConnections + 1) { fixture in
      do {
        try await operation(fixture)
      } catch {
        try await fixture.pool.query("DELETE FROM wire_link_metadata_cache WHERE canonical_key LIKE \(fixture.prefix + "%")", logger: fixture.logger)
        throw error
      }
      try await fixture.pool.query("DELETE FROM wire_link_metadata_cache WHERE canonical_key LIKE \(fixture.prefix + "%")", logger: fixture.logger)
    }
  }

  private func isolatedDeadlineClaim(
    _ fixture: WireRollupIntegrationFixture, store: PostgresWireLinkMetadataStore,
    limit: Int, asOf: Date
  ) async throws -> [WireLinkMetadataTarget] {
    // Prevent claiming another test's rows; release before trigger DDL teardown.
    try await fixture.pool.withTransaction(logger: fixture.logger) { isolation in
      try await isolation.query("SELECT canonical_key FROM wire_link_metadata_cache WHERE canonical_key NOT LIKE \(fixture.prefix + "%") FOR UPDATE", logger: fixture.logger)
      return try await store.claimDue(limit: limit, asOf: asOf)
    }
  }

  private func seedDeadlineMetadata(_ fixture: WireRollupIntegrationFixture) async throws -> String {
    let key = try await fixture.item("deadline")
    try await fixture.pool.query("INSERT INTO wire_link_metadata_cache (canonical_key, canonical_url, status, retry_after) VALUES (\(key), 'https://example.com/deadline', 'pending', \(Date(timeIntervalSince1970: 0)))", logger: fixture.logger)
    return key
  }

  private func assertDeadlineMetadataPending(_ fixture: WireRollupIntegrationFixture, key: String) async throws {
    let rows = try await fixture.pool.query("SELECT status, retry_after FROM wire_link_metadata_cache WHERE canonical_key = \(key)", logger: fixture.logger)
    for try await row in rows {
      let value = try row.decode((String, Date).self)
      #expect(value.0 == "pending")
      #expect(value.1 == Date(timeIntervalSince1970: 0))
    }
  }
}
