import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("incremental refresh tracks feedback changes, moved signals, future dates and unchanged transport")
  func incrementalRollupMutationParity() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let oldKey = try await fixture.item("old")
      let newKey = try await fixture.item("new")
      let future = try await fixture.item("future")
      try await fixture.signal(oldKey, actor: "a", occurredAt: fixture.now)
      try await fixture.signal(future, actor: "future", occurredAt: fixture.now.addingTimeInterval(3_600))
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(future)["signals_1h"] == 1)
      try await fixture.pool.query(
        "UPDATE wire_signal_events SET ingested_at = ingested_at + interval '1 second' WHERE canonical_key = \(oldKey)",
        logger: fixture.logger)
      var rows = try await fixture.pool.query(
        "SELECT count(*)::bigint FROM wire_signal_rollup_dirty WHERE canonical_key = \(oldKey)", logger: fixture.logger)
      for try await row in rows { #expect(try row.decode(Int64.self) == 0) }
      try await fixture.pool.query(
        "UPDATE wire_signal_events SET canonical_key = \(newKey) WHERE canonical_key = \(oldKey)", logger: fixture.logger)
      try await fixture.pool.query(
        """
        INSERT INTO wire_article_feedback
          (canonical_key, actor_key_hash, source_uri, feedback_value, occurred_at, expires_at)
        VALUES (\(newKey), 'feedback-actor-hash', \(newKey), 'good', \(fixture.now),
          \(fixture.now.addingTimeInterval(86_400)))
        """, logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.snapshot(oldKey) == nil)
      #expect(try await fixture.counts(newKey)["positive_feedback_24h"] == 1)
      try await fixture.pool.query(
        "UPDATE wire_article_feedback SET feedback_value = 'not_good' WHERE canonical_key = \(newKey)", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(newKey)["positive_feedback_24h"] == 0)
      #expect(try await fixture.counts(newKey)["negative_feedback_24h"] == 1)
      let incremental = try await fixture.counts(newKey)
      let oracle = PostgresWireSignalRollupStore(pool: fixture.pool, logger: fixture.logger)
      try await oracle.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(newKey) == incremental)
      try await fixture.store.refresh(asOf: fixture.now)
      try await fixture.pool.query(
        "DELETE FROM wire_article_feedback WHERE canonical_key = \(newKey)", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(newKey)["negative_feedback_24h"] == 0)
      rows = try await fixture.pool.query(
        "SELECT count(*)::bigint FROM wire_signal_rollup_dirty WHERE canonical_key = \(newKey)", logger: fixture.logger)
      for try await row in rows { #expect(try row.decode(Int64.self) == 0) }
    }
  }

  @Test("incremental acknowledgment preserves concurrent revisions and transactional rollback")
  func incrementalRollupPreservesConcurrentDirtyRevision() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("concurrent")
      try await fixture.signal(key, actor: "first", occurredAt: fixture.now)
      try await fixture.store.refresh(asOf: fixture.now)
      try await fixture.signal(key, actor: "second", occurredAt: fixture.now)
      try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
        let ready = try await fixture.store.prepareIncrementalRefresh(connection: connection, asOf: fixture.now)
        #expect(ready)
        // Separate connection commits after work was snapshotted. Publication
        // must acknowledge only the claimed revision, never this newer one.
        try await fixture.signal(key, actor: "third", occurredAt: fixture.now)
        try await connection.query(
          "CREATE TEMP TABLE wire_signal_rollups_next ON COMMIT DROP AS SELECT rollup.*, now() + interval '1 hour' AS next_due_at FROM wire_signal_rollups rollup",
          logger: fixture.logger)
        try await fixture.store.finishIncrementalRefresh(connection: connection, asOf: fixture.now)
      }
      let rows = try await fixture.pool.query(
        "SELECT count(*)::bigint FROM wire_signal_rollup_dirty WHERE canonical_key = \(key)", logger: fixture.logger)
      for try await row in rows { #expect(try row.decode(Int64.self) == 1) }
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_7d"] == 3)
      await #expect(throws: (any Error).self) {
        try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          try await connection.query(
            "DELETE FROM wire_signal_events WHERE canonical_key = \(key)", logger: fixture.logger)
          try await connection.query("SELECT 1 / 0", logger: fixture.logger)
        }
      }
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_7d"] == 3)
    }
  }

  @Test("incremental coverage rebuilds after lost derived state, source truncate and backward time")
  func incrementalRollupRebuildsCoverage() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("rebuild")
      try await fixture.signal(key, actor: "first", occurredAt: fixture.now.addingTimeInterval(-3_600))
      try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(1))
      #expect(try await fixture.counts(key)["signals_1h"] == 0)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_1h"] == 1)
      try await fixture.pool.query("TRUNCATE wire_signal_rollups", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_7d"] == 1)
      try await fixture.pool.query(
        "TRUNCATE wire_signal_rollup_dirty, wire_signal_rollup_schedule", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(1))
      #expect(try await fixture.counts(key)["signals_1h"] == 0)
      // A simulated postmaster identity change exercises the same coverage
      // invalidation used when unlogged relations are reset after a crash.
      try await fixture.pool.query(
        "UPDATE wire_signal_rollup_control SET postmaster_started_at = '-infinity'", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_1h"] == 1)
      try await fixture.pool.query("TRUNCATE wire_signal_events", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.snapshot(key) == nil)
    }
  }

  @Test("incremental refresh detects partition detach and reattachment without row triggers")
  func incrementalRollupPartitionTopology() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("partition")
      let future = Date(timeIntervalSince1970: 3_471_292_800) // 2080-01-01 UTC
      try await fixture.signal(key, actor: "future", occurredAt: future)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_7d"] == 1)
      try await fixture.pool.query(
        "ALTER TABLE wire_signal_events DETACH PARTITION wire_signal_events_20800101",
        logger: fixture.logger)
      do {
        try await fixture.store.refresh(asOf: fixture.now)
        #expect(try await fixture.snapshot(key) == nil)
        try await fixture.pool.query(
          "ALTER TABLE wire_signal_events ATTACH PARTITION wire_signal_events_20800101 FOR VALUES FROM ('2080-01-01') TO ('2080-01-02')",
          logger: fixture.logger)
        try await fixture.store.refresh(asOf: fixture.now)
        #expect(try await fixture.counts(key)["signals_7d"] == 1)
      } catch {
        try await fixture.pool.query("DROP TABLE IF EXISTS wire_signal_events_20800101", logger: fixture.logger)
        throw error
      }
      try await fixture.pool.query("DROP TABLE wire_signal_events_20800101", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.snapshot(key) == nil)
    }
  }


  @Test("incremental publication skips dirty rows held by an ingestion transaction")
  func incrementalRollupSkipsLockedAcknowledgments() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("locked-dirty")
      try await fixture.signal(key, actor: "first", occurredAt: fixture.now)
      try await fixture.store.refresh(asOf: fixture.now)
      try await fixture.signal(key, actor: "second", occurredAt: fixture.now)
      try await fixture.pool.withTransaction(logger: fixture.logger) { writer in
        // Bound a regression in this test: a waiting acknowledgment must not
        // hang the suite forever while the independent source lock is held.
        try await writer.query("SET LOCAL idle_in_transaction_session_timeout = '3s'", logger: fixture.logger)
        try await writer.query(
          "SELECT revision FROM wire_signal_rollup_dirty WHERE canonical_key = \(key) FOR UPDATE",
          logger: fixture.logger)
        let start = ContinuousClock.now
        try await fixture.store.refresh(asOf: fixture.now)
        #expect(start.duration(to: .now) < .seconds(2))
        let pending = try await writer.query(
          "SELECT count(*)::bigint FROM wire_signal_rollup_dirty WHERE canonical_key = \(key)", logger: fixture.logger)
        for try await row in pending { #expect(try row.decode(Int64.self) == 1) }
      }
      #expect(try await fixture.counts(key)["signals_7d"] == 2)
      try await fixture.store.refresh(asOf: fixture.now)
      let pending = try await fixture.pool.query(
        "SELECT count(*)::bigint FROM wire_signal_rollup_dirty WHERE canonical_key = \(key)", logger: fixture.logger)
      for try await row in pending { #expect(try row.decode(Int64.self) == 0) }
    }
  }


  @Test("incremental feedback ages at inclusive daily and exclusive expiry boundaries")
  func incrementalRollupFeedbackBoundaries() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let daily = try await fixture.item("feedback-daily")
      let expiry = try await fixture.item("feedback-expiry")
      for key in [daily, expiry] {
        try await fixture.signal(key, actor: "baseline", occurredAt: fixture.now)
      }
      try await fixture.pool.query(
        """
        INSERT INTO wire_article_feedback
          (canonical_key, actor_key_hash, source_uri, feedback_value, occurred_at, expires_at)
        VALUES (\(daily), 'feedback-actor-hash', \(daily), 'good',
                \(fixture.now.addingTimeInterval(-86_400)), \(fixture.now.addingTimeInterval(60))),
               (\(expiry), 'feedback-actor-hash', \(expiry), 'not_good',
                \(fixture.now), \(fixture.now.addingTimeInterval(1)))
        """, logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(daily)["positive_feedback_24h"] == 1)
      #expect(try await fixture.counts(expiry)["negative_feedback_24h"] == 1)
      try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(0.001))
      #expect(try await fixture.counts(daily)["positive_feedback_24h"] == 0)
      #expect(try await fixture.counts(expiry)["negative_feedback_24h"] == 1)
      try await fixture.store.refresh(asOf: fixture.now.addingTimeInterval(1))
      #expect(try await fixture.counts(expiry)["negative_feedback_24h"] == 0)
      try await fixture.pool.query("TRUNCATE wire_article_feedback", logger: fixture.logger)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(daily)["positive_feedback_24h"] == 0)
      #expect(try await fixture.counts(expiry)["negative_feedback_24h"] == 0)
    }
  }


  @Test("incremental and full snapshots match all fields with duplicate actors and future feedback")
  func incrementalRollupAllFieldsParity() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("all-fields")
      let feedbackOnly = try await fixture.item("feedback-only")
      let kinds = ["share", "quote", "recommendation", "reply", "like", "repost", "publication"]
      let ages = [-600.0, 0.0, 60.0, 3_600.0, 86_400.0, 604_800.0]
      for (index, age) in ages.enumerated() {
        for (kindIndex, kind) in kinds.enumerated() {
          try await fixture.signal(
            key, actor: "repeated-\(kindIndex % 3)", occurredAt: fixture.now.addingTimeInterval(-age),
            kind: kind, collection: index % 2 == 0 ? "app.bsky.feed.post" : "network.cosmik.card",
            community: kindIndex % 2 == 0 ? "community-a" : "community-b")
        }
      }
      for feedbackKey in [key, feedbackOnly] {
        try await fixture.pool.query(
          """
          INSERT INTO wire_article_feedback
            (canonical_key, actor_key_hash, source_uri, feedback_value, occurred_at, expires_at)
          VALUES (\(feedbackKey), 'feedback-actor-hash', \(feedbackKey), 'good',
            \(fixture.now.addingTimeInterval(60)), \(fixture.now.addingTimeInterval(600)))
          """, logger: fixture.logger)
      }
      try await fixture.store.refresh(asOf: fixture.now)
      let incremental = try #require(try await fixture.values(key))
      #expect(try await fixture.values(feedbackOnly) == nil)
      #expect(try await fixture.counts(key)["positive_feedback_24h"] == 1)
      let oracle = PostgresWireSignalRollupStore(pool: fixture.pool, logger: fixture.logger)
      try await oracle.refresh(asOf: fixture.now)
      #expect(try await fixture.values(key) == incremental)
      #expect(try await fixture.values(feedbackOnly) == nil)
    }
  }


  @Test("tracking cutover drains untracked writers and a disabled gate retains the full reader")
  func incrementalRollupTrackingCutover() async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      let key = try await fixture.item("cutover")
      try await fixture.signal(key, actor: "before", occurredAt: fixture.now)
      let store = PostgresWireSignalRollupStore(
        pool: fixture.pool, logger: fixture.logger, incrementalEnabled: true)
      try await store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_7d"] == 1)
      let enabling = try await fixture.pool.withTransaction(logger: fixture.logger) { writer in
        try await writer.query(
          """
          INSERT INTO wire_signal_events
            (event_key, canonical_key, signal_kind, actor_key_hash, source_uri,
             occurred_at, expires_at, source_collection, source_action)
          VALUES (\(key), \(key), 'share', 'untracked-writer-actor', \(key),
            \(fixture.now), \(fixture.now.addingTimeInterval(86_400)), 'app.bsky.feed.post', 'share')
          """, logger: fixture.logger)
        let enabling = Task {
          try await fixture.pool.query("SELECT wire_set_signal_rollup_tracking(true)", logger: fixture.logger)
        }
        var observedLock = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline && !observedLock {
          try await writer.query("SELECT pg_stat_clear_snapshot()", logger: fixture.logger)
          let rows = try await writer.query(
            """
            SELECT EXISTS (SELECT 1 FROM pg_stat_activity
              WHERE pid <> pg_backend_pid() AND wait_event_type = 'Lock'
                AND query LIKE '%wire_set_signal_rollup_tracking(true)%')
            """, logger: fixture.logger)
          for try await row in rows { observedLock = try row.decode(Bool.self) }
          if !observedLock { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(observedLock)
        return enabling
      }
      _ = try await enabling.value
      do {
        // This writer committed before tracking became active, so only the
        // mandatory first full rebuild can discover it.
        try await store.refresh(asOf: fixture.now)
        #expect(try await fixture.counts(key)["signals_7d"] == 2)
        try await fixture.pool.query("SELECT wire_set_signal_rollup_tracking(false)", logger: fixture.logger)
        try await fixture.signal(key, actor: "after-disable", occurredAt: fixture.now)
        try await store.refresh(asOf: fixture.now)
        #expect(try await fixture.counts(key)["signals_7d"] == 3)
      } catch {
        try await fixture.pool.query("SELECT wire_set_signal_rollup_tracking(false)", logger: fixture.logger)
        throw error
      }
    }
  }


  @Test("incremental JIT override ends with the refresh transaction")
  func incrementalRollupJITScope() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      try await fixture.pool.withConnection { connection in
        var original = "on"
        for try await row in try await connection.query("SHOW jit", logger: fixture.logger) {
          original = try row.decode(String.self)
        }
        try await connection.query("SET jit = on", logger: fixture.logger)
        do {
          try await connection.query("BEGIN", logger: fixture.logger)
          #expect(try await fixture.store.prepareIncrementalRefresh(connection: connection, asOf: fixture.now))
          for try await row in try await connection.query("SHOW jit", logger: fixture.logger) {
            #expect(try row.decode(String.self) == "off")
          }
          try await connection.query("ROLLBACK", logger: fixture.logger)
          for try await row in try await connection.query("SHOW jit", logger: fixture.logger) {
            #expect(try row.decode(String.self) == "on")
          }
          try await connection.query("SELECT set_config('jit', \(original), false)", logger: fixture.logger)
        } catch {
          try await connection.query("ROLLBACK", logger: fixture.logger)
          try await connection.query("SELECT set_config('jit', \(original), false)", logger: fixture.logger)
          throw error
        }
      }
    }
  }

}
