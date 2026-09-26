import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("the pre-snapshot topology lock allows ingestion and excludes attach and detach")
  func rollupTopologyLockAndSnapshotOrder() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("topology-lock")
      try await fixture.pool.query(
        "SELECT ensure_wire_signal_event_partition(\(fixture.now)::date)", logger: fixture.logger)
      try await fixture.pool.query(
        "CREATE TABLE wire_rollup_attach_test (LIKE wire_signal_events INCLUDING DEFAULTS INCLUDING CONSTRAINTS)",
        logger: fixture.logger)
      try await fixture.pool.query(
        "CREATE TABLE wire_rollup_detach_test PARTITION OF wire_signal_events FOR VALUES FROM ('2099-12-29') TO ('2099-12-30')",
        logger: fixture.logger)
      do {
        try await fixture.pool.withTransaction(logger: fixture.logger) { reader in
          try await fixture.store.configureRefreshSnapshot(connection: reader)
          // This commits after the utility lock but before the first snapshot.
          // Seeing it proves the lock did not accidentally freeze the snapshot.
          try await fixture.signal(key, actor: "during-lock", occurredAt: fixture.now)
          #expect(try await fixture.store.prepareIncrementalRefresh(connection: reader, asOf: fixture.now))
          let signals = try await reader.query(
            "SELECT count(*) FROM wire_signal_events WHERE canonical_key = \(key)", logger: fixture.logger)
          for try await row in signals { #expect(try row.decode(Int64.self) == 1) }
          for attach in [false, true] {
            do {
              // CONCURRENTLY is intentionally outside a transaction: its
              // weaker parent lock was compatible with the old ACCESS SHARE.
              try await fixture.pool.withConnection { ddl in
                try await ddl.query("SET lock_timeout = '100ms'", logger: fixture.logger)
                do {
                  if attach {
                    try await ddl.query(
                      "ALTER TABLE wire_signal_events ATTACH PARTITION wire_rollup_attach_test FOR VALUES FROM ('2099-12-30') TO ('2099-12-31')",
                      logger: fixture.logger)
                  } else {
                    try await ddl.query(
                      "ALTER TABLE wire_signal_events DETACH PARTITION wire_rollup_detach_test CONCURRENTLY",
                      logger: fixture.logger)
                  }
                  try await ddl.query("SET lock_timeout = DEFAULT", logger: fixture.logger)
                } catch {
                  try await ddl.query("SET lock_timeout = DEFAULT", logger: fixture.logger)
                  throw error
                }
              }
              Issue.record("Partition topology must stay fixed through publication")
            } catch let error as PSQLError {
              #expect(error.serverInfo?[.sqlState] == "55P03")
            }
          }
        }
        try await fixture.pool.query("DROP TABLE wire_rollup_attach_test, wire_rollup_detach_test", logger: fixture.logger)
      } catch {
        try await fixture.pool.query("DROP TABLE wire_rollup_attach_test, wire_rollup_detach_test", logger: fixture.logger)
        throw error
      }
    }
  }

  @Test("busy topology maintenance fails promptly and cancellation releases the refresh lock")
  func rollupTopologyLockBudgetsAndCancellation() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      try await fixture.pool.withTransaction(logger: fixture.logger) { maintainer in
        try await maintainer.query("LOCK TABLE ONLY wire_signal_events IN SHARE UPDATE EXCLUSIVE MODE", logger: fixture.logger)
        let start = ContinuousClock.now
        do {
          try await fixture.store.refresh(asOf: fixture.now)
          Issue.record("Busy topology maintenance must retain its lock")
        } catch let error as PostgresTransactionError {
          let cause = try #require(error.closureError as? PSQLError)
          #expect(cause.serverInfo?[.sqlState] == "55P03")
          #expect(!PostgresWireSignalRollupStore.canRetryRefresh(error))
        }
        #expect(start.duration(to: .now) < .seconds(1))
      }
      let cancelled = Task {
        try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          try await fixture.store.configureRefreshSnapshot(connection: connection)
          withUnsafeCurrentTask { $0?.cancel() }
          try Task.checkCancellation()
        }
      }
      await #expect(throws: (any Error).self) { try await cancelled.value }
      try await fixture.store.refresh(asOf: fixture.now)
    }
  }
}
