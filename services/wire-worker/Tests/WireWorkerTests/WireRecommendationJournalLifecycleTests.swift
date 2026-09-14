import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("a recommendation before its own document no longer deadlocks the repository")
  func recommendationJournalAllowsDocumentFollower() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      let payload = """
        {"commit":{"record":{"$type":"site.standard.document","url":"https://example.com/\(fixture.environment)","title":"Deferred Dependency Integration Story","createdAt":"\(fixture.now.ISO8601Format())"}}}
        """
      try await fixture.pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, collection, operation, record_key, payload, event_time, next_attempt_at)
        VALUES (\(fixture.environment), 'live', 2, 'test', 'jetstream_v2_seq', 'commit',
                \(fixture.repoDID), 'site.standard.document', 'create', 'first',
                \(payload)::jsonb, \(fixture.now.addingTimeInterval(2)), \(fixture.now))
        """, logger: fixture.logger)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      #expect(try await fixture.apply(sequence: 2) == .applied)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.subject())") == 1)
      #expect(try await fixture.recover().resolved == 1)
      #expect(try await fixture.signalCount() == 1)
    }
  }

  @Test("deactivating an account prevents a pending recommendation from reappearing")
  func recommendationJournalHonorsAccountDeactivation() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      try await fixture.pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, payload, event_time, next_attempt_at)
        VALUES (\(fixture.environment), 'live', 2, 'test', 'jetstream_v2_seq', 'account',
                \(fixture.repoDID), '{"account":{"active":false}}'::jsonb,
                \(fixture.now.addingTimeInterval(2)), \(fixture.now))
        """, logger: fixture.logger)
      #expect(try await fixture.apply(sequence: 2) == .applied)
      _ = try await fixture.publishSubject()
      _ = try await fixture.recover()
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.journalStatus(sequence: 1) == "superseded")
      try await fixture.pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, payload, event_time, next_attempt_at)
        VALUES (\(fixture.environment), 'live', 3, 'test', 'jetstream_v2_seq', 'account',
                \(fixture.repoDID), '{"account":{"active":true}}'::jsonb,
                \(fixture.now.addingTimeInterval(3)), \(fixture.now))
        """, logger: fixture.logger)
      #expect(try await fixture.apply(sequence: 3) == .applied)
      _ = try await fixture.recover(asOf: fixture.now.addingTimeInterval(1_200))
      #expect(try await fixture.signalCount() == 0)
      // A genuinely later user mutation may create a new recommendation.
      try await fixture.insertRecommendation(sequence: 4, operation: "update")
      #expect(try await fixture.apply(sequence: 4) == .applied)
      #expect(try await fixture.signalCount() == 1)
    }
  }

  @Test("recovery honors its source generation and environment scope")
  func recommendationJournalRecoveryScope() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      _ = try await fixture.publishSubject()
      for excludedScope in [
        WireInboxSourceScope(environment: fixture.environment, sourceGenerations: ["replay"]),
        WireInboxSourceScope(environment: "different-environment", sourceGenerations: ["live"]),
      ] {
        let counts = try await fixture.journal.recover(
          asOf: fixture.now.addingTimeInterval(600), limit: 100, sourceScope: excludedScope)
        #expect(counts.attempted == 0)
        #expect(try await fixture.signalCount() == 0)
        #expect(try await fixture.journalStatus(sequence: 1) == "pending")
      }
      #expect(try await fixture.recover().resolved == 1)
    }
  }

  @Test("environment recovery includes durable work from retired ingestion generations")
  func recommendationJournalRetiredGenerationRecovery() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1, generation: "replay")
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .deferred)
      _ = try await fixture.publishSubject()
      let excluded = try await fixture.journal.recover(
        asOf: fixture.now.addingTimeInterval(600), limit: 100,
        sourceScope: WireInboxSourceScope(environment: "different-environment", sourceGenerations: []))
      #expect(excluded.attempted == 0)
      #expect(try await fixture.signalCount() == 0)
      let recovered = try await fixture.journal.recover(
        asOf: fixture.now.addingTimeInterval(600), limit: 100,
        sourceScope: WireInboxSourceScope(environment: fixture.environment, sourceGenerations: []))
      #expect(recovered.resolved == 1)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.journalStatus(sequence: 1, generation: "replay") == "resolved")
    }
  }

  @Test("a dependency arriving beyond the signal window retains an explicit expired journal envelope")
  func recommendationJournalRetainsExpiredDependency() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      _ = try await fixture.publishSubject()
      _ = try await fixture.recover(asOf: fixture.now.addingTimeInterval(8 * 86_400))
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.journalStatus(sequence: 1) == "expired")
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_journal
        WHERE environment = \(fixture.environment)
          AND payload -> 'commit' -> 'record' ->> 'document' = \(fixture.subject())
        """) == 1)
    }
  }

  @Test("incomparable cross-host versions remain durable conflicts without altering a newer signal")
  func recommendationJournalQuarantinesAmbiguousVersion() async throws {
    try await WireRecommendationJournalFixture.run { fixture in
      _ = try await fixture.publishSubject()
      try await fixture.insertRecommendation(sequence: 1, revision: "unknown-revision")
      #expect(try await fixture.apply(sequence: 1) == .applied)
      try await fixture.insertRecommendation(
        sequence: 2, operation: "delete", generation: "replay", revision: "unknown-revision",
        sourceHost: "different-sequence-domain")
      #expect(try await fixture.apply(sequence: 2, generation: "replay") == .deferred)
      #expect(try await fixture.journalStatus(sequence: 2, generation: "replay") == "conflict")
      #expect(try await fixture.signalCount() == 1)
      _ = try await fixture.recover()
      #expect(try await fixture.signalCount() == 1)
    }
  }
}
