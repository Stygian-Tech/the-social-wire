import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("the first rollout phase journals missing dependencies while retaining the repository barrier")
  func recommendationJournalDisabledGateRetainsBarrier() async throws {
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
      let event = try await fixture.claim(sequence: 1)
      let firstPhase = try fixture.processor(enabled: false)
      let outcome = try await firstPhase.applyClaimed(event, asOf: fixture.now.addingTimeInterval(60))
      #expect(outcome == .retry)
      #expect(!outcome.permitsContinuation)
      #expect(try await fixture.journalStatus(sequence: 1) == "pending")
      #expect(try await fixture.signalCount() == 0)
      #expect(try await firstPhase.claimNext(in: event.repository, asOf: fixture.now.addingTimeInterval(60)) == nil)
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.environment) AND seq = 1 AND status = 'retry'
          AND applied_at IS NULL
        """) == 1)

      // Once every writer has version fencing, enable the separately controlled handoff.
      #expect(try await fixture.apply(sequence: 1, asOf: fixture.now.addingTimeInterval(100)) == .deferred)
      #expect(try await fixture.apply(sequence: 2, asOf: fixture.now.addingTimeInterval(100)) == .applied)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_recommendation_journal WHERE environment = \(fixture.environment)") == 1)
    }
  }

  @Test("cleanup requires a durable journal before deleting handed-off inbox rows", arguments: [false, true])
  func recommendationJournalCleanupProof(scoped: Bool) async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      try await fixture.pool.query(
        """
        UPDATE wire_ingestion_inbox SET expires_at = \(fixture.now.addingTimeInterval(-1))
        WHERE environment = \(fixture.environment) AND seq = 1
        """, logger: fixture.logger)
      try await fixture.pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, payload, event_time, next_attempt_at, status, expires_at,
           lease_owner, lease_token, lease_expires_at)
        SELECT \(fixture.environment), 'live', sequence, 'test', 'jetstream_v2_seq', 'identity',
               \(fixture.repoDID), '{}'::jsonb, \(fixture.now), \(fixture.now), state,
               \(fixture.now.addingTimeInterval(-1)),
               CASE WHEN state = 'leased' THEN 'active-owner' END,
               CASE WHEN state = 'leased' THEN 'active-lease' END,
               CASE WHEN state = 'leased' THEN \(fixture.now.addingTimeInterval(600)) END
        FROM (VALUES (2, 'deferred'), (3, 'pending'), (4, 'leased'), (5, 'superseded'))
          fixture(sequence, state)
        """, logger: fixture.logger)
      try await fixture.pool.query(
        "INSERT INTO wire_ingestion_admission (environment, retained_rows) VALUES (\(fixture.environment), 5)",
        logger: fixture.logger)

      _ = try await fixture.processor(scoped: scoped).deleteTerminal(
        asOf: fixture.now.addingTimeInterval(60), batchSize: 5_000)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.environment) AND seq = 1") == 0)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.environment) AND seq IN (2, 3, 4, 5)") == 4)
      #expect(try await fixture.scalar(
        "SELECT retained_rows FROM wire_ingestion_admission WHERE environment = \(fixture.environment)") == 4)
      #expect(try await fixture.journalStatus(sequence: 1) == "pending")
      _ = try await fixture.publishSubject()
      #expect(try await fixture.recover().resolved == 1)
    }
  }
}
