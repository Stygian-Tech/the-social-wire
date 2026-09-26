import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("committed dirty revisions cannot starve exact repeatable-read publication")
  func incrementalRollupDefersConflictingAcknowledgment() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true, maximumConnections: 4) { fixture in
      let key = try await fixture.item("acknowledgment")
      try await fixture.signal(key, actor: "first", occurredAt: fixture.now)
      try await fixture.store.refresh(asOf: fixture.now)
      try await fixture.signal(key, actor: "second", occurredAt: fixture.now)
      // Force a known claimed lane independent of backend PID allocation.
      try await fixture.pool.query(
        "DELETE FROM wire_signal_rollup_dirty WHERE canonical_key = \(key)", logger: fixture.logger)
      try await fixture.pool.query(
        "INSERT INTO wire_signal_rollup_dirty (canonical_key, shard) VALUES (\(key), 0)",
        logger: fixture.logger)

      let refresh = try await fixture.pool.withTransaction(logger: fixture.logger) { blocker in
        try await blocker.query("SET LOCAL idle_in_transaction_session_timeout = '15s'", logger: fixture.logger)
        let lockRows = try await blocker.query(
          "SELECT pg_backend_pid() FROM wire_signal_rollups WHERE canonical_key = \(key) FOR UPDATE",
          logger: fixture.logger)
        var blockerPID: Int32 = 0
        for try await row in lockRows { blockerPID = try row.decode(Int32.self) }
        #expect(blockerPID != 0)
        let refresh = Task { try await fixture.store.refresh(asOf: fixture.now) }
        do {
          // Hold publication only, allowing source writers to commit after the
          // refresher has selected work and computed its exact source snapshot.
          var publicationBlocked = false
          for _ in 0..<250 {
            let rows = try await fixture.pool.query(
              """
              SELECT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE \(blockerPID) = ANY(pg_blocking_pids(pid))
                  AND query LIKE '%UPDATE wire_signal_rollups current%'
              )
              """, logger: fixture.logger)
            for try await row in rows { publicationBlocked = try row.decode(Bool.self) }
            if publicationBlocked { break }
            try await Task.sleep(for: .milliseconds(20))
          }
          try #require(publicationBlocked)
          // The partition already exists. Calling ensure_partition here would
          // intentionally contend with the refresher's topology protection.
          let eventKey = fixture.prefix + "-concurrent-third"
          try await fixture.pool.query(
            """
            INSERT INTO wire_signal_events
              (event_key, canonical_key, signal_kind, actor_key_hash, source_uri,
               occurred_at, expires_at, source_collection, source_action)
            VALUES (\(eventKey), \(key), 'share', 'actor-hash-for-third',
              \("at://did:example:test/app.bsky.feed.post/" + eventKey), \(fixture.now),
              \(fixture.now.addingTimeInterval(14 * 86_400)), 'app.bsky.feed.post', 'share')
            """, logger: fixture.logger)
          try await fixture.pool.query(
            """
            INSERT INTO wire_signal_rollup_dirty (canonical_key, shard) VALUES (\(key), 0)
            ON CONFLICT (canonical_key, shard) DO UPDATE SET revision = EXCLUDED.revision
            """, logger: fixture.logger)
          return refresh
        } catch {
          refresh.cancel()
          throw error
        }
      }
      try await refresh.value
      // The concurrent third event belongs to the next snapshot; restarting the
      // whole transaction would publish three and hide the original starvation.
      #expect(try await fixture.counts(key)["signals_7d"] == 2)
      let retained = try await fixture.pool.query(
        "SELECT count(*) FROM wire_signal_rollup_dirty WHERE canonical_key = \(key) AND shard = 0",
        logger: fixture.logger)
      for try await row in retained { #expect(try row.decode(Int64.self) == 1) }

      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_7d"] == 3)
      let selective = try await fixture.values(key)
      let oracle = PostgresWireSignalRollupStore(pool: fixture.pool, logger: fixture.logger)
      try await oracle.refresh(asOf: fixture.now)
      #expect(try await fixture.values(key) == selective)
      let drained = try await fixture.pool.query(
        "SELECT count(*) FROM wire_signal_rollup_dirty WHERE canonical_key = \(key)", logger: fixture.logger)
      for try await row in drained { #expect(try row.decode(Int64.self) == 0) }
    }
  }

  @Test("non-serialization acknowledgment errors still roll back publication")
  func incrementalRollupAcknowledgmentFailureRollsBack() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("acknowledgment-error")
      try await fixture.signal(key, actor: "first", occurredAt: fixture.now)
      try await fixture.store.refresh(asOf: fixture.now)
      let before = try await fixture.snapshot(key)
      try await fixture.signal(key, actor: "second", occurredAt: fixture.now)
      try await fixture.pool.query(
        """
        CREATE FUNCTION wire_rollup_ack_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'injected acknowledgment failure' USING ERRCODE = 'P0001'; END $$
        """, logger: fixture.logger)
      try await fixture.pool.query(
        "CREATE TRIGGER wire_rollup_ack_test BEFORE DELETE ON wire_signal_rollup_dirty FOR EACH ROW EXECUTE FUNCTION wire_rollup_ack_test_fail()",
        logger: fixture.logger)
      do {
        do {
          try await fixture.store.refresh(asOf: fixture.now)
          Issue.record("Non-serialization acknowledgment errors must abort publication")
        } catch {
          #expect(!PostgresWireSignalRollupStore.canRetryRefresh(error))
          let transaction = try #require(error as? PostgresTransactionError)
          let postgres = try #require(transaction.closureError as? PSQLError)
          #expect(postgres.serverInfo?[.sqlState] == "P0001")
        }
        #expect(try await fixture.snapshot(key) == before)
        try await fixture.pool.query("DROP FUNCTION wire_rollup_ack_test_fail() CASCADE", logger: fixture.logger)
      } catch {
        try await fixture.pool.query("DROP FUNCTION wire_rollup_ack_test_fail() CASCADE", logger: fixture.logger)
        throw error
      }
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_7d"] == 2)
    }
  }

}
