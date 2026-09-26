import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("a signal moved between batches uses one snapshot and retains its concurrent revision")
  func rollupBatchSnapshotExcludesConcurrentMove() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let early = try await fixture.item("a")
      let late = try await fixture.item("z")
      try await fixture.signal(early, actor: "first", occurredAt: fixture.now)
      do {
        try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          try await fixture.store.configureRefreshSnapshot(connection: connection)
          #expect(try await fixture.store.prepareIncrementalRefresh(connection: connection, asOf: fixture.now))
          try await connection.query(
            """
            INSERT INTO wire_signal_rollup_keys (canonical_key)
            SELECT \(fixture.prefix + "-m") || lpad(n::text, 4, '0') FROM generate_series(1, 1000) n
            UNION SELECT \(late)
            """, logger: fixture.logger)
          try await connection.query(
            "CREATE TEMP TABLE wire_signal_rollups_next (LIKE wire_signal_rollups INCLUDING DEFAULTS, next_due_at timestamptz) ON COMMIT DROP",
            logger: fixture.logger)
          let firstBatch = try #require(try await fixture.store.selectNextIncrementalBatch(
            connection: connection, afterKey: nil))
          try await fixture.store.stageAggregates(connection: connection, asOf: fixture.now, incremental: true)
          try await fixture.pool.query(
            "UPDATE wire_signal_events SET canonical_key = \(late) WHERE canonical_key = \(early)",
            logger: fixture.logger)
          // Force a revised claimed lane as well as the writer's own hint;
          // backend-PID sharding can otherwise create a different safe lane.
          try await fixture.pool.query(
            "UPDATE wire_signal_rollup_dirty SET revision = nextval('wire_signal_rollup_revision') WHERE canonical_key = \(early)",
            logger: fixture.logger)
          #expect(try await fixture.store.selectNextIncrementalBatch(connection: connection, afterKey: firstBatch) != nil)
          try await fixture.store.stageAggregates(connection: connection, asOf: fixture.now, incremental: true)
          let staged = try await connection.query(
            "SELECT canonical_key, signals_7d FROM wire_signal_rollups_next ORDER BY canonical_key",
            logger: fixture.logger)
          var seen: [String] = []
          for try await row in staged {
            let (key, count) = try row.decode((String, Int64).self)
            seen.append(key)
            #expect(count == 1)
          }
          #expect(seen == [early])
          try await fixture.store.finishIncrementalRefresh(connection: connection, asOf: fixture.now)
        }
        Issue.record("A concurrent dirty revision must abort repeatable-read acknowledgment")
      } catch {
        #expect(PostgresWireSignalRollupStore.canRetryRefresh(error))
        var transaction = try #require(error as? PostgresTransactionError)
        transaction.commitError = CancellationError()
        #expect(!PostgresWireSignalRollupStore.canRetryRefresh(transaction))
        transaction.commitError = nil
        transaction.rollbackError = CancellationError()
        #expect(!PostgresWireSignalRollupStore.canRetryRefresh(transaction))
        #expect(!PostgresWireSignalRollupStore.canRetryRefresh(CancellationError()))
      }
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.values(early) == nil)
      #expect(try await fixture.counts(late)["signals_7d"] == 1)
    }
  }

  @Test("serialization retries replay the entire refresh and stop after three attempts", arguments: [false, true])
  func rollupSerializationRetryBudget(alwaysFails: Bool) async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("serialization")
      try await fixture.signal(key, actor: "first", occurredAt: fixture.now)
      try await fixture.pool.query("CREATE SEQUENCE wire_rollup_retry_test_sequence", logger: fixture.logger)
      try await fixture.pool.query(
        """
        CREATE FUNCTION wire_rollup_retry_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF nextval('wire_rollup_retry_test_sequence') <= 2 THEN
            RAISE EXCEPTION 'injected serialization failure' USING ERRCODE = '40001';
          END IF;
          RETURN NEW;
        END $$
        """, logger: fixture.logger)
      // A sequence survives rollback, making retry counts deterministic. The
      // persistent branch uses a threshold above the bounded attempt budget.
      if alwaysFails {
        try await fixture.pool.query("ALTER SEQUENCE wire_rollup_retry_test_sequence RESTART WITH -10 MINVALUE -10", logger: fixture.logger)
      }
      try await fixture.pool.query(
        "CREATE TRIGGER wire_rollup_retry_test BEFORE INSERT ON wire_signal_rollups FOR EACH ROW EXECUTE FUNCTION wire_rollup_retry_test_fail()",
        logger: fixture.logger)
      do {
        if alwaysFails {
          await #expect(throws: (any Error).self) { try await fixture.store.refresh(asOf: fixture.now) }
          #expect(try await fixture.values(key) == nil)
        } else {
          try await fixture.store.refresh(asOf: fixture.now)
          #expect(try await fixture.counts(key)["signals_7d"] == 1)
        }
        let attempts = try await fixture.pool.query("SELECT last_value FROM wire_rollup_retry_test_sequence", logger: fixture.logger)
        for try await row in attempts { #expect(try row.decode(Int64.self) == (alwaysFails ? -8 : 3)) }
        try await fixture.pool.query("DROP FUNCTION wire_rollup_retry_test_fail() CASCADE", logger: fixture.logger)
        try await fixture.pool.query("DROP SEQUENCE wire_rollup_retry_test_sequence", logger: fixture.logger)
      } catch {
        try await fixture.pool.query("DROP FUNCTION wire_rollup_retry_test_fail() CASCADE", logger: fixture.logger)
        try await fixture.pool.query("DROP SEQUENCE wire_rollup_retry_test_sequence", logger: fixture.logger)
        throw error
      }
    }
  }
}
