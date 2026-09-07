import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("a deferred recommendation releases its repository without falsely reporting application")
  func recommendationJournalReleasesMissingDependency() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      try await fixture.pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, payload, event_time, next_attempt_at)
        VALUES (\(fixture.environment), 'live', 2, 'test', 'jetstream_v2_seq', 'identity',
                \(fixture.repoDID), '{}'::jsonb, \(fixture.now), \(fixture.now))
        """, logger: fixture.logger)

      let outcome = try await fixture.apply(sequence: 1)
      #expect(outcome == .deferred)
      #expect(outcome.permitsContinuation)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.journalStatus(sequence: 1) == "pending")
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.environment) AND seq = 1
          AND status = 'deferred' AND applied_at IS NULL
          AND lease_token IS NULL
        """) == 1)
      #expect(try await fixture.apply(sequence: 2) == .applied)

      // A disposable inbox may disappear on restart. Its durable handoff must not.
      try await fixture.pool.query(
        "DELETE FROM wire_ingestion_inbox WHERE environment = \(fixture.environment)", logger: fixture.logger)
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM pg_class
        WHERE relname IN ('wire_recommendation_journal', 'wire_recommendation_record_fences',
                          'wire_recommendation_account_fences')
          AND relpersistence = 'p'
        """) == 3)
      let canonicalKey = try await fixture.publishSubject()
      let recovered = try await fixture.recover()
      #expect(recovered.resolved == 1)
      #expect(try await fixture.journalStatus(sequence: 1) == "resolved")
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI) AND canonical_key = \(canonicalKey)") == 1)
      let secondRecovery = try await fixture.recover(asOf: fixture.now.addingTimeInterval(1_200))
      #expect(secondRecovery.resolved == 0)
      #expect(try await fixture.signalCount() == 1)
    }
  }

  @Test("a delete before its missing subject appears permanently supersedes the pending recommendation")
  func recommendationJournalDeleteBeforeDependency() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      try await fixture.insertRecommendation(sequence: 2, operation: "delete")
      #expect(try await fixture.apply(sequence: 2) == .applied)
      _ = try await fixture.publishSubject()
      _ = try await fixture.recover()
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.journalStatus(sequence: 1) == "superseded")
      #expect(try await fixture.journalStatus(sequence: 2) == "deleted")

      // Replaying an earlier generation must not resurrect a deleted record.
      try await fixture.insertRecommendation(
        sequence: 1, generation: "replay", occurredAt: fixture.now,
        revision: "3m22222222223")
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .terminal)
      _ = try await fixture.recover(asOf: fixture.now.addingTimeInterval(1_200))
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.journalStatus(sequence: 1, generation: "replay") == "superseded")
    }
  }

  @Test("a newer recommendation update resolves only its replacement subject")
  func recommendationJournalUpdateReplacesDependency() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      try await fixture.insertRecommendation(sequence: 2, operation: "update", subject: fixture.subject("replacement"))
      #expect(try await fixture.apply(sequence: 2) == .deferred)
      let originalKey = try await fixture.publishSubject()
      _ = try await fixture.recover()
      #expect(try await fixture.signalCount() == 0)
      let replacementKey = try await fixture.publishSubject("replacement")
      _ = try await fixture.recover(asOf: fixture.now.addingTimeInterval(1_200))
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI) AND canonical_key = \(originalKey)") == 0)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI) AND canonical_key = \(replacementKey)") == 1)
      #expect(try await fixture.journalStatus(sequence: 1) == "superseded")
    }
  }

  @Test("journal handoff rejects a stale lease and a cancelled caller before creating durable work")
  func recommendationJournalLeaseAndCancellationFencing() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      let event = try await fixture.claim(sequence: 1)
      try await fixture.pool.query(
        """
        UPDATE wire_ingestion_inbox SET lease_token = 'replacement-token'
        WHERE environment = \(fixture.environment) AND seq = 1
        """, logger: fixture.logger)
      #expect(try await fixture.processor().applyClaimed(event, asOf: fixture.now.addingTimeInterval(60)) == .leaseLost)
      #expect(try await fixture.journalStatus(sequence: 1) == nil)
      let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await fixture.processor().applyClaimed(event, asOf: fixture.now.addingTimeInterval(60))
      }
      await #expect(throws: CancellationError.self) { try await cancelled.value }
      #expect(try await fixture.journalStatus(sequence: 1) == nil)
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.environment) AND seq = 1
          AND status = 'leased' AND lease_token = 'replacement-token'
        """) == 1)
    }
  }

  @Test("replaying a committed journal handoff is idempotent")
  func recommendationJournalDuplicateDelivery() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      _ = try await fixture.publishSubject()
      try await fixture.insertRecommendation(sequence: 1)
      let event = try await fixture.claim(sequence: 1)
      let processor = try fixture.processor()
      #expect(try await processor.applyClaimed(event, asOf: fixture.now.addingTimeInterval(60)) == .applied)
      #expect(try await processor.applyClaimed(event, asOf: fixture.now.addingTimeInterval(60)) == .leaseLost)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_recommendation_journal WHERE environment = \(fixture.environment)") == 1)
      try await fixture.insertRecommendation(sequence: 1, generation: "replay")
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .terminal)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.journalStatus(sequence: 1, generation: "replay") == "superseded")
      #expect(try await fixture.actorSignalCount() == 1)
    }
  }

  @Test("a resolved durable recommendation can restore its lost unlogged signal once")
  func recommendationJournalRestoresLostProjection() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      _ = try await fixture.publishSubject()
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      try await fixture.pool.query(
        "DELETE FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI)", logger: fixture.logger)
      try await fixture.pool.query(
        "DELETE FROM wire_ingestion_inbox WHERE environment = \(fixture.environment)", logger: fixture.logger)
      #expect(try await fixture.signalCount() == 0)
      _ = try await fixture.recover()
      #expect(try await fixture.signalCount() == 1)
      _ = try await fixture.recover(asOf: fixture.now.addingTimeInterval(1_200))
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.actorSignalCount() == 1)
    }
  }

  @Test("concurrent recovery workers publish a deferred recommendation only once")
  func recommendationJournalConcurrentRecovery() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      _ = try await fixture.publishSubject()
      async let first = fixture.recover()
      async let second = fixture.recover()
      _ = try await (first, second)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.journalStatus(sequence: 1) == "resolved")
    }
  }

  @Test("a signal on another date cannot hide the missing projection of a journal event")
  func recommendationJournalRecoveryMatchesEventDate() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      _ = try await fixture.publishSubject()
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      let differentDate = fixture.now.addingTimeInterval(-86_400)
      try await fixture.pool.query(
        "SELECT ensure_wire_signal_event_partition((\(differentDate) AT TIME ZONE 'UTC')::date)",
        logger: fixture.logger)
      // Preserve the transport identity but move the row to a different day.
      // The current journal event's projection is therefore still missing.
      try await fixture.pool.query(
        "UPDATE wire_signal_events SET occurred_at = \(differentDate) WHERE source_uri = \(fixture.sourceURI)",
        logger: fixture.logger)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.recover().resolved == 1)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_signal_events
        WHERE source_uri = \(fixture.sourceURI) AND occurred_at = \(fixture.now.addingTimeInterval(1))
        """) == 1)
      #expect(try await fixture.actorSignalCount() == 1)
    }
  }
}
