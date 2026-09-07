import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

// Extend the existing serialized suite: refresh replaces a database-wide
// derived snapshot, so these fixtures must not race other ingestion tests.
extension WirePostgresIntegrationTests {
  @Test("rollup refresh preserves unchanged tuples and exact baseline counts")
  func rollupRefreshSkipsUnchangedRows() async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      let key = try await fixture.item("baseline")
      try await fixture.signal(
        key, actor: "baseline", occurredAt: fixture.now.addingTimeInterval(-60),
        community: "community-test")
      try await fixture.signal(
        key, actor: "external", occurredAt: fixture.now.addingTimeInterval(-30),
        kind: "recommendation", collection: "network.cosmik.card")
      try await fixture.pool.query(
        """
        INSERT INTO wire_article_feedback
          (canonical_key, actor_key_hash, source_uri, feedback_value, occurred_at, expires_at)
        VALUES (\(key), 'feedback-actor-hash', \(key), 'good', \(fixture.now),
                \(fixture.now.addingTimeInterval(86_400)))
        """, logger: fixture.logger)

      try await fixture.store.refresh(asOf: fixture.now)
      let before = try #require(try await fixture.snapshot(key))
      let counts = try await fixture.counts(key)
      #expect(counts["signals_7d"] == 2)
      #expect(counts["baseline_signals_7d"] == 1)
      #expect(counts["recommendations_24h"] == 1)
      #expect(counts["baseline_recommendations_24h"] == 0)
      #expect(counts["shares_24h"] == 2)
      #expect(counts["baseline_shares_24h"] == 1)
      #expect(counts["communities_24h"] == 1)
      #expect(counts["positive_feedback_24h"] == 1)

      try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(1))
      #expect(try await fixture.snapshot(key) == before)

      try await fixture.pool.query(
        "UPDATE wire_signal_events SET community_key_hash = NULL WHERE canonical_key = \(key)",
        logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(2))
      #expect(try await fixture.snapshot(key) != before)
      #expect(try await fixture.counts(key)["communities_24h"] == 0)
      let rows = try await fixture.pool.query(
        "SELECT primary_community_key_hash FROM wire_signal_rollups WHERE canonical_key = \(key)",
        logger: fixture.logger)
      for try await row in rows { #expect(try row.decode(String?.self) == nil) }
    }
  }

  @Test("rollups age exactly across hourly daily and weekly windows and signal expiry")
  func rollupRefreshExpiresWindows() async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      let hourly = try await fixture.item("hourly")
      let daily = try await fixture.item("daily")
      let weekly = try await fixture.item("weekly")
      let expiring = try await fixture.item("expiring")
      let deleted = try await fixture.item("deleted")
      for (key, age) in [(hourly, 3_600), (daily, 86_400), (weekly, 7 * 86_400)] {
        try await fixture.signal(
          key, actor: key, occurredAt: fixture.now.addingTimeInterval(Double(-age)))
      }
      try await fixture.signal(
        expiring, actor: expiring, occurredAt: fixture.now,
        expiresAt: fixture.now.addingTimeInterval(1))
      try await fixture.signal(deleted, actor: deleted, occurredAt: fixture.now)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(hourly)["signals_1h"] == 1)
      #expect(try await fixture.counts(daily)["signals_24h"] == 1)
      #expect(try await fixture.counts(weekly)["signals_7d"] == 1)

      try await fixture.pool.query(
        "DELETE FROM wire_signal_events WHERE canonical_key = \(deleted)", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(1))
      #expect(try await fixture.counts(hourly)["signals_1h"] == 0)
      #expect(try await fixture.counts(hourly)["signals_24h"] == 1)
      #expect(try await fixture.counts(daily)["signals_24h"] == 0)
      #expect(try await fixture.counts(daily)["signals_7d"] == 1)
      #expect(try await fixture.snapshot(weekly) == nil)
      #expect(try await fixture.snapshot(expiring) == nil)
      #expect(try await fixture.snapshot(deleted) == nil)
    }
  }

  @Test("a failed refresh rolls back changes and leaves the complete prior snapshot")
  func rollupRefreshRollsBackAtomically() async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      let key = try await fixture.item("rollback")
      let removed = try await fixture.item("rollback-removed")
      try await fixture.signal(key, actor: key, occurredAt: fixture.now)
      try await fixture.signal(removed, actor: removed, occurredAt: fixture.now)
      try await fixture.store.refresh(asOf: fixture.now)
      let before = try #require(try await fixture.snapshot(key))
      let beforeRemoved = try #require(try await fixture.snapshot(removed))
      try await fixture.signal(key, actor: "second", occurredAt: fixture.now)
      try await fixture.pool.query(
        "DELETE FROM wire_signal_events WHERE canonical_key = \(removed)", logger: fixture.logger)
      // Trigger failure after changed-row updates, at the insert phase. The
      // deliberately narrow fixture trigger never affects non-test rows.
      try await fixture.pool.query(
        """
        CREATE FUNCTION wire_rollup_test_fail_insert() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.canonical_key LIKE 'rollup-test-%-rollback-insert' THEN
            RAISE EXCEPTION 'injected rollup publication failure';
          END IF;
          RETURN NEW;
        END $$
        """, logger: fixture.logger)
      try await fixture.pool.query(
        """
        CREATE TRIGGER wire_rollup_test_fail_insert BEFORE INSERT ON wire_signal_rollups
        FOR EACH ROW EXECUTE FUNCTION wire_rollup_test_fail_insert()
        """, logger: fixture.logger)
      do {
        let inserted = try await fixture.item("rollback-insert")
        try await fixture.signal(inserted, actor: inserted, occurredAt: fixture.now)
        await #expect(throws: (any Error).self) {
          try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(1))
        }
        #expect(try await fixture.snapshot(key) == before)
        #expect(try await fixture.snapshot(removed) == beforeRemoved)
        #expect(try await fixture.snapshot(inserted) == nil)
        try await fixture.pool.query(
          "DROP FUNCTION IF EXISTS wire_rollup_test_fail_insert() CASCADE", logger: fixture.logger)
        try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(1))
        #expect(try await fixture.counts(key)["signals_7d"] == 2)
        #expect(try await fixture.snapshot(removed) == nil)
        #expect(try await fixture.snapshot(inserted) != nil)
      } catch {
        try await fixture.pool.query(
          "DROP FUNCTION IF EXISTS wire_rollup_test_fail_insert() CASCADE", logger: fixture.logger)
        throw error
      }
    }
  }
}
