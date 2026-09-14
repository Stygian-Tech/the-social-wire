import Foundation
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("publication recovery reproduces exact activity without moving checkpoints or pending rows")
  func publicationRecoveryExactAndIdempotent() async throws {
    try await WirePublicationRecoveryFixture.run { fixture in
      let source = fixture.source
      let originalTime = fixture.base.now.addingTimeInterval(-3600)
      try await source.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        operation: "create", occurredAt: originalTime)
      #expect(try await source.apply(sequence: 1) == .applied)
      let actorActivity = try await source.actorSignals()
      try await fixture.loseSignal()
      try await source.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision)
      try await fixture.register()
      let recovery = try fixture.recovery
      #expect(try await recovery.runBatch(asOf: fixture.epoch, limit: 1) == 1)
      #expect(try await source.signalCount() == 1)
      #expect(try await source.actorSignals() == actorActivity)
      let expectedHash = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8)).hash(source.author)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(source.sourceURI)
          AND event_key = \(fixture.base.environment + ":live:1")
          AND transport_event_key = \("transport:" + fixture.base.environment + ":jetstream.example.test:jetstream_v2_seq:1")
          AND actor_key_hash = \(expectedHash) AND occurred_at = \(originalTime)
          AND expires_at = \(originalTime.addingTimeInterval(WireDataPolicy.signalRetention))
        """) == 1)
      #expect(try await recovery.runBatch(asOf: fixture.epoch, limit: 1) == 0)
      #expect(try await recovery.runBatch(asOf: fixture.epoch, limit: 1) == 0)
      #expect(try await source.signalCount() == 1)
      #expect(try await source.projectionExists())
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM appview_jetstream_checkpoints WHERE environment = \(fixture.base.environment) AND last_staged_seq = 0 AND replay_state = 'replaying'") == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.base.environment) AND seq = 2 AND status = 'pending'") == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_publication_signal_recovery_jobs WHERE environment = \(fixture.base.environment) AND completed_at IS NOT NULL AND replay_completed_at IS NULL") == 1)
    }
  }

  @Test("publication recovery rejects snapshots, expired activity, later versions, and account retractions",
    arguments: ["snapshot", "expired", "boundary", "newer", "account", "wrongSource", "beyondCheckpoint", "wrongEpoch"])
  func publicationRecoveryNeverInventsOrResurrects(reason: String) async throws {
    try await WirePublicationRecoveryFixture.run { fixture in
      let source = fixture.source
      let eventTime = reason == "expired" ? fixture.epoch.addingTimeInterval(-WireDataPolicy.signalRetention - 1)
        : reason == "boundary" ? fixture.epoch.addingTimeInterval(-WireDataPolicy.signalRetention) : fixture.base.now
      try await source.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        snapshot: reason == "snapshot", operation: reason == "snapshot" ? "update" : "create", occurredAt: eventTime)
      #expect(try await source.apply(sequence: 1) == .applied)
      try await fixture.loseSignal()
      try await fixture.register(maximumSequence: reason == "beyondCheckpoint" ? 0 : 100)
      if reason == "newer" {
        try await source.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision, operation: "delete")
        #expect(try await source.apply(sequence: 2) == .applied)
      } else if reason == "account" {
        try await source.insertAccount(sequence: 2, active: false, occurredAt: fixture.base.now.addingTimeInterval(30))
        #expect(try await source.apply(sequence: 2) == .applied)
      } else if reason == "wrongSource" {
        try await fixture.base.pool.query("UPDATE appview_jetstream_checkpoints SET source_host='other.example.test' WHERE environment=\(fixture.base.environment)", logger: fixture.base.logger)
      } else if reason == "wrongEpoch" {
        try await fixture.base.pool.query("UPDATE wire_ingestion_inbox_epochs SET initialized_at=\(fixture.epoch.addingTimeInterval(1)) WHERE environment=\(fixture.base.environment)", logger: fixture.base.logger)
      }
      _ = try await fixture.recovery.runBatch(asOf: fixture.epoch)
      #expect(try await source.signalCount() == 0)
    }
  }

  @Test("publication recovery requires an explicit crash job and preserves existing newer signals")
  func publicationRecoveryRequiresJobAndKeepsSignals() async throws {
    try await WirePublicationRecoveryFixture.run { fixture in
      try await fixture.source.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, operation: "create")
      #expect(try await fixture.source.apply(sequence: 1) == .applied)
      let recovery = try fixture.recovery
      #expect(try await recovery.runBatch(asOf: fixture.epoch) == 0)
      try await fixture.register()
      let newerTime = fixture.base.now.addingTimeInterval(20)
      try await fixture.base.pool.query(
        "UPDATE wire_signal_events SET occurred_at=\(newerTime) WHERE source_uri=\(fixture.source.sourceURI)", logger: fixture.base.logger)
      #expect(try await recovery.runBatch(asOf: fixture.epoch) == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri=\(fixture.source.sourceURI) AND occurred_at=\(newerTime)") == 1)
    }
  }

  @Test("a failed publication recovery page rolls back inserted signals and its cursor")
  func publicationRecoveryPageRollback() async throws {
    try await WirePublicationRecoveryFixture.run { fixture in
      try await fixture.source.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, operation: "create")
      #expect(try await fixture.source.apply(sequence: 1) == .applied)
      try await fixture.loseSignal()
      try await fixture.register()
      try await fixture.base.pool.query(
        """
        CREATE FUNCTION wire_recovery_test_reject_cursor() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'intentional recovery rollback test'; END $$
        """, logger: fixture.base.logger)
      try await fixture.base.pool.query(
        "CREATE TRIGGER wire_recovery_test_reject_cursor BEFORE UPDATE ON wire_publication_signal_recovery_jobs FOR EACH ROW EXECUTE FUNCTION wire_recovery_test_reject_cursor()",
        logger: fixture.base.logger)
      var failed = false
      do { _ = try await fixture.recovery.runBatch(asOf: fixture.epoch) }
      catch { failed = true }
      try await fixture.base.pool.query("DROP TRIGGER wire_recovery_test_reject_cursor ON wire_publication_signal_recovery_jobs", logger: fixture.base.logger)
      try await fixture.base.pool.query("DROP FUNCTION wire_recovery_test_reject_cursor()", logger: fixture.base.logger)
      #expect(failed)
      #expect(try await fixture.source.signalCount() == 0)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_publication_signal_recovery_jobs WHERE environment=\(fixture.base.environment) AND after_source_uri='' AND completed_at IS NULL") == 1)
      #expect(try await fixture.recovery.runBatch(asOf: fixture.epoch) == 1)
      #expect(try await fixture.source.signalCount() == 1)
    }
  }

  @Test("seed completion stays degraded until the source is live and unresolved inbox work is reconciled")
  func publicationRecoveryCompletionDoesNotClaimReplay() async throws {
    try await WirePublicationRecoveryFixture.run { fixture in
      try await fixture.register()
      let recovery = try fixture.recovery
      #expect(try await recovery.runBatch(asOf: fixture.epoch) == 0)
      try await fixture.source.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision)
      try await fixture.base.pool.query(
        "UPDATE appview_jetstream_checkpoints SET replay_state='live', last_staged_seq=100 WHERE environment=\(fixture.base.environment)", logger: fixture.base.logger)
      for status in ["pending", "deferred", "dead_letter"] {
        try await fixture.base.pool.query(
          "UPDATE wire_ingestion_inbox SET status=\(status), dead_lettered_at=\(fixture.epoch) WHERE environment=\(fixture.base.environment)", logger: fixture.base.logger)
        _ = try await recovery.runBatch(asOf: fixture.epoch)
        #expect(try await fixture.base.scalar(
          "SELECT COUNT(*)::bigint FROM wire_publication_signal_recovery_jobs WHERE environment=\(fixture.base.environment) AND replay_completed_at IS NULL") == 1)
      }
      try await fixture.base.pool.query(
        "UPDATE wire_ingestion_inbox SET status='superseded' WHERE environment=\(fixture.base.environment)", logger: fixture.base.logger)
      _ = try await recovery.runBatch(asOf: fixture.epoch)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_publication_signal_recovery_jobs WHERE environment=\(fixture.base.environment) AND replay_completed_at IS NOT NULL") == 1)
    }
  }
}
