import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("a newer live delete prevents an older PDS snapshot from restoring the record",
    arguments: ["site.standard.document", "site.standard.entry", "site.standard.publication"])
  func standardFenceDeleteRejectsOlderSnapshot(collection: String) async throws {
    try await WireSourceVersionFixture.run(collection: collection) { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, operation: "create")
      #expect(try await fixture.apply(sequence: 1) == .applied)
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision, operation: "delete")
      #expect(try await fixture.apply(sequence: 2) == .applied)
      #expect(try await fixture.projectionExists() == false)
      let activityBefore = try await fixture.actorSignals()
      try await fixture.insert(sequence: 3, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.apply(sequence: 3) == .terminal)
      #expect(try await fixture.projectionExists() == false)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.actorSignals() == activityBefore)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_standard_record_fences
        WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI)
          AND operation = 'delete' AND repo_rev = \(WireSourceVersionFixture.newerRevision)
        """) == 1)
    }
  }

  @Test("a newer live update is not overwritten by an older authoritative observation",
    arguments: ["site.standard.document", "site.standard.entry", "site.standard.publication"])
  func standardFenceUpdateRejectsOlderSnapshot(collection: String) async throws {
    try await WireSourceVersionFixture.run(collection: collection) { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.newerRevision, title: "Newer Article")
      #expect(try await fixture.apply(sequence: 1) == .applied)
      let activityBefore = try await fixture.actorSignals()
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.apply(sequence: 2) == .terminal)
      #expect(try await fixture.title() == "Newer Article")
      #expect(try await fixture.actorSignals() == activityBefore)
    }
  }

  @Test("a snapshot projection yields to a newer live delete")
  func standardFenceSnapshotThenDelete() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      #expect(try await fixture.projectionExists())
      #expect(try await fixture.actorSignals() == 0)
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision, operation: "delete")
      #expect(try await fixture.apply(sequence: 2) == .applied)
      #expect(try await fixture.projectionExists() == false)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.actorSignals() == 0)
    }
  }

  @Test("an older live replay cannot replace a newer snapshot or create fresh activity")
  func standardFenceOlderLiveReplayAfterSnapshot() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.newerRevision, title: "Current Snapshot", snapshot: true)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, operation: "create", generation: "replay")
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .terminal)
      #expect(try await fixture.title() == "Current Snapshot")
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.actorSignals() == 0)
    }
  }

  @Test("same-version live replays repair lost projections without recounting activity")
  func standardFenceIdempotentVersionAcrossGenerations() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let originalTime = fixture.base.now.addingTimeInterval(-3_600)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        operation: "create", occurredAt: originalTime)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      let originalActivity = try await fixture.actorSignals()
      try await fixture.base.pool.query(
        "DELETE FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)", logger: fixture.base.logger)
      try await fixture.base.pool.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI)", logger: fixture.base.logger)
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.olderRevision,
        generation: "replay", occurredAt: fixture.base.now, sourceHost: "other-jetstream.example.test")
      #expect(try await fixture.apply(sequence: 2, generation: "replay") == .applied)
      #expect(try await fixture.projectionExists())
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.actorSignals() == originalActivity)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI) AND occurred_at = \(originalTime)") == 1)
    }
  }

  @Test("a later same-CID snapshot preserves the original live activity and rejects an intermediate delete")
  func standardFenceSnapshotWatermarkPreservesLiveAnchor() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let originalTime = fixture.base.now.addingTimeInterval(-3_600)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        operation: "create", occurredAt: originalTime)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      let originalActivity = try await fixture.actorSignals()
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision,
        snapshot: true, cid: WireSourceVersionFixture.olderCID)
      #expect(try await fixture.apply(sequence: 2) == .applied)
      #expect(try await fixture.actorSignals() == originalActivity)
      try await fixture.base.pool.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI)", logger: fixture.base.logger)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        generation: "replay", occurredAt: fixture.base.now, sourceHost: "other-jetstream.example.test")
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .applied)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.actorSignals() == originalActivity)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI) AND occurred_at = \(originalTime)") == 1)

      try await fixture.insert(sequence: 2, revision: "3m22222222224", operation: "delete", generation: "replay")
      #expect(try await fixture.apply(sequence: 2, generation: "replay") == .terminal)
      #expect(try await fixture.projectionExists())
      #expect(try await fixture.signalCount() == 1)
    }
  }

  @Test("a same-CID live commit observed after a snapshot contributes only its real original activity")
  func standardFenceSnapshotFirstRetainsRealLiveTime() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.newerRevision,
        snapshot: true, cid: WireSourceVersionFixture.olderCID)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      #expect(try await fixture.signalCount() == 0)
      let originalTime = fixture.base.now.addingTimeInterval(-7_200)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        operation: "create", generation: "replay", occurredAt: originalTime)
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .applied)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.actorSignals() == 1)
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.olderRevision,
        generation: "replay", occurredAt: fixture.base.now)
      #expect(try await fixture.apply(sequence: 2, generation: "replay") == .applied)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.actorSignals() == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI) AND occurred_at = \(originalTime)") == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_items WHERE canonical_key = \(fixture.key) AND last_signal_at = \(originalTime)") == 1)
    }
  }

  @Test("incomparable live and snapshot versions preserve the accepted value and retry")
  func standardFenceUnknownOrderFailsClosed() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.newerRevision, title: "Accepted Snapshot", snapshot: true)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      try await fixture.insert(sequence: 1, revision: "unknown-revision", title: "Unordered Live Replay", generation: "replay")
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .retry)
      #expect(try await fixture.title() == "Accepted Snapshot")
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.base.environment) AND source_generation = 'replay'
          AND status = 'retry' AND applied_at IS NULL
          AND failure_reason = 'standard_record_order_conflict' AND expires_at > NOW() + INTERVAL '100 years'
        """) == 1)
    }
  }

  @Test("a later replay observation cannot bypass the original activity account-retraction cutoff")
  func standardFenceReplayRespectsOriginalAccountCutoff() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let originalTime = fixture.base.now.addingTimeInterval(-3_600)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        operation: "create", occurredAt: originalTime)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      #expect(try await fixture.signalCount() == 1)
      try await fixture.insertAccount(sequence: 2, active: false,
        occurredAt: fixture.base.now.addingTimeInterval(-1_800))
      #expect(try await fixture.apply(sequence: 2) == .applied)
      try await fixture.insertAccount(sequence: 3, active: true,
        occurredAt: fixture.base.now.addingTimeInterval(-900))
      #expect(try await fixture.apply(sequence: 3) == .applied)
      #expect(try await fixture.signalCount() == 0)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        generation: "replay", occurredAt: fixture.base.now, sourceHost: "other-jetstream.example.test")
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .terminal)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.actorSignals() == 0)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_standard_record_fences
        WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI)
          AND event_time = \(originalTime)
        """) == 1)
    }
  }

  @Test("concurrent snapshot claims converge on the newer record version")
  func standardFenceConcurrentVersions() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.newerRevision,
        title: "Newest Concurrent Snapshot", snapshot: true, generation: "replay")
      let oldEvent = try await fixture.claim(sequence: 1)
      let newEvent = try await fixture.claim(sequence: 1, generation: "replay")
      let processor = try fixture.base.processor()
      async let older = processor.applyClaimed(oldEvent, asOf: fixture.base.now.addingTimeInterval(60))
      async let newer = processor.applyClaimed(newEvent, asOf: fixture.base.now.addingTimeInterval(60))
      let results = try await (older, newer)
      #expect(results.0 == .applied || results.0 == .terminal)
      #expect(results.1 == .applied)
      #expect(try await fixture.title() == "Newest Concurrent Snapshot")
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.actorSignals() == 0)
    }
  }

  @Test("a conflict that becomes applicable under the lock retries before publishing an unresolved projection")
  func standardFenceRechecksSkippedResolution() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        title: "Original Snapshot", snapshot: true)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      try await fixture.insert(sequence: 3, revision: "opaque-live-revision",
        title: "Resolved After Retry", generation: "replay")
      let event = try await fixture.claim(sequence: 3, generation: "replay")
      let processor = try fixture.base.processor()
      let applying = try await fixture.base.pool.withTransaction(logger: fixture.base.logger) { connection in
        try await connection.query(
          """
          SELECT pg_advisory_xact_lock(hashtextextended(
            \("wire-recommendation-account:" + fixture.base.environment + ":" + fixture.author), 0))
          """, logger: fixture.base.logger)
        var observedPID: Int64?
        for try await row in try await connection.query("SELECT pg_backend_pid()::bigint", logger: fixture.base.logger) {
          observedPID = try row.decode(Int64.self)
        }
        let blockingPID = try #require(observedPID)
        let task = Task {
          try await processor.applyClaimed(event, asOf: fixture.base.now.addingTimeInterval(60))
        }
        do {
          var waiting = false
          for _ in 0..<100 {
            let blocked = try await fixture.base.scalar(
              "SELECT COUNT(*)::bigint FROM pg_stat_activity WHERE \(blockingPID)::integer = ANY(pg_blocking_pids(pid))")
            if blocked > 0 { waiting = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
          }
          // Waiting for the account lock proves the candidate already performed
          // its conflict preflight and skipped external projection preparation.
          try #require(waiting)
          try await connection.query(
            """
            UPDATE wire_standard_record_fences
            SET event_kind = 'commit', source_host = 'jetstream.example.test',
                cursor_kind = 'jetstream_v2_seq', source_generation = 'live', seq = 2,
                operation = 'update', repo_rev = '3m22222222224', observed_repo_rev = NULL,
                record_cid = \(WireSourceVersionFixture.newerCID)
            WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI)
            """, logger: fixture.base.logger)
          return task
        } catch {
          task.cancel()
          throw error
        }
      }
      #expect(try await applying.value == .retry)
      #expect(try await fixture.title() == "Original Snapshot")
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.base.environment) AND source_generation = 'replay'
          AND seq = 3 AND status = 'retry' AND applied_at IS NULL
          AND failure_reason = 'standard_record_resolve_again'
        """) == 1)
      let retried = try #require(try await processor.claimNext(
        in: event.repository, asOf: fixture.base.now.addingTimeInterval(100)))
      #expect(try await processor.applyClaimed(retried, asOf: fixture.base.now.addingTimeInterval(100)) == .applied)
      #expect(try await fixture.title() == "Resolved After Retry")
      #expect(try await fixture.signalCount() == 1)
    }
  }

  @Test("a stale standard-record lease cannot establish a version fence")
  func standardFenceRejectsReplacedLease() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.newerRevision)
      let event = try await fixture.claim(sequence: 1)
      try await fixture.base.pool.query(
        "UPDATE wire_ingestion_inbox SET lease_token = 'replacement-token' WHERE environment = \(fixture.base.environment)",
        logger: fixture.base.logger)
      #expect(try await fixture.base.processor().applyClaimed(event, asOf: fixture.base.now.addingTimeInterval(60)) == .leaseLost)
      #expect(try await fixture.projectionExists() == false)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_standard_record_fences WHERE environment = \(fixture.base.environment)") == 0)
    }
  }

  @Test("a source version fence is isolated from a different environment")
  func standardFenceEnvironmentIsolation() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.newerRevision, operation: "delete")
      #expect(try await fixture.apply(sequence: 1) == .applied)
      try await WireRecommendationJournalFixture.run { otherBase in
        let other = WireSourceVersionFixture(base: otherBase, author: fixture.author)
        do {
          try await other.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
          #expect(try await other.apply(sequence: 1) == .applied)
          #expect(try await other.projectionExists())
          #expect(try await otherBase.scalar(
            "SELECT COUNT(*)::bigint FROM wire_standard_record_fences WHERE environment = \(otherBase.environment)") == 1)
          try await otherBase.pool.query(
            "DELETE FROM wire_standard_record_fences WHERE environment = \(otherBase.environment)", logger: otherBase.logger)
        } catch {
          _ = try? await otherBase.pool.query(
            "DELETE FROM wire_standard_record_fences WHERE environment = \(otherBase.environment)", logger: otherBase.logger)
          throw error
        }
      }
    }
  }
}
