import Foundation
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("recommendations beyond signal retention retain their envelope without dependency network work")
  func recommendationHydrationSkipsExpiredSignals() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      let later = fixture.base.now.addingTimeInterval(8 * 86_400)
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: later, limit: 16)
      #expect(await fixture.verifier.calls().isEmpty)
      let journal = PostgresWireRecommendationJournal(pool: fixture.base.pool,
        logger: fixture.base.logger, dependencyVerificationEnabled: true)
      _ = try await journal.recover(asOf: later, limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.base.journalStatus(sequence: 1) == "expired")
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_journal
        WHERE environment = \(fixture.base.environment) AND operation = 'create'
          AND payload->'commit'->'record'->>'document' = \(fixture.subjectURI)
        """) == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.subjectURI)") == 0)
      #expect(try await fixture.signalCount() == 0)
    }
  }

  @Test("dependency hydration bounds concurrent verification and stages a shared subject once")
  func recommendationHydrationBoundsConcurrency() async throws {
    let verifier = WireHydrationVerifierFixture(delayNanoseconds: 20_000_000)
    try await WireRecommendationHydrationFixture.run(verifier: verifier) { fixture in
      for sequence in Int64(1)...6 { try await fixture.seed(sequence) }
      try await fixture.base.pool.query(
        "INSERT INTO wire_ingestion_admission (environment, retained_rows) VALUES (\(fixture.base.environment), 100)",
        logger: fixture.base.logger)
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 6)
      let maximum = await verifier.maximumConcurrency()
      #expect(maximum > 1)
      #expect(maximum <= 2)
      let calls = await verifier.calls()
      for sequence in Int64(1)...6 {
        #expect(calls.contains { $0.uri == fixture.sourceURI(sequence) && $0.expectedCID == fixture.cid })
      }
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.base.environment) AND event_kind = 'snapshot'
          AND repo_did = \(fixture.authorDID) AND collection = 'site.standard.document'
        """) == 1)
      #expect(try await fixture.base.scalar(
        "SELECT retained_rows FROM wire_ingestion_admission WHERE environment = \(fixture.base.environment)") == 101)
    }
  }

  @Test("authoritative unavailable observations retain the original envelope without a fabricated deletion",
    arguments: ["absent", "changed", "inactive"])
  func recommendationHydrationRetainsUnavailable(status: String) async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      let metadata = fixture.observation()
      let result: WirePublicRecordVerification
      switch status {
      case "absent": result = .missing(metadata)
      case "changed": result = .changed(currentCID: WireSourceVersionFixture.newerCID, observation: metadata)
      default: result = .inactive(metadata)
      }
      await fixture.verifier.set(result, for: fixture.sourceURI())
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_dependency_recovery
        WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI())
          AND status = \(status)
        """) == 1)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_journal
        WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI())
          AND operation = 'create' AND record_cid = \(fixture.cid)
          AND payload->'commit'->'record'->>'document' = \(fixture.subjectURI)
          AND status NOT IN ('resolved', 'deleted')
        """) == 1)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.base.environment)
          AND (operation = 'delete' OR status = 'applied' OR event_kind = 'snapshot')
        """) == 0)
      let calls = await fixture.verifier.calls()
      #expect(calls.allSatisfy { $0.uri == fixture.sourceURI() })
    }
  }

  @Test("transient hydration errors keep durable work and respect the scheduled retry")
  func recommendationHydrationHonorsRetry() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      await fixture.verifier.fail(.transientStatus(503), for: fixture.sourceURI())
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      let initialCalls = await fixture.verifier.calls().count
      #expect(initialCalls == 1)
      _ = try await hydrator.hydrate(asOf: fixture.base.now.addingTimeInterval(1), limit: 16)
      #expect(await fixture.verifier.calls().count == initialCalls)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_dependency_recovery
        WHERE environment = \(fixture.base.environment) AND next_attempt_at > \(fixture.base.now.addingTimeInterval(1))
        """) == 1)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.base.journalStatus(sequence: 1) == "pending")
    }
  }
}

extension WirePostgresIntegrationTests {
  @Test("a shared alias cannot resolve a deferred recommendation before its current identity is verified")
  func recommendationHydrationVerifiesExistingAlias() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      try await fixture.preseedItem()
      let journal = PostgresWireRecommendationJournal(pool: fixture.base.pool,
        logger: fixture.base.logger, dependencyVerificationEnabled: true)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(60), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.signalCount() == 0)
      try await fixture.base.pool.query(
        "UPDATE wire_recommendation_journal SET next_attempt_at = \(fixture.base.now.addingTimeInterval(3_600)) WHERE environment = \(fixture.base.environment)",
        logger: fixture.base.logger)
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now.addingTimeInterval(60), limit: 16)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(120), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.signalCount() == 1)
      let calls = await fixture.verifier.calls()
      #expect(calls.contains { $0.uri == fixture.sourceURI() && $0.expectedCID == fixture.cid })
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_items WHERE canonical_key = \(fixture.key) AND NOT eligible AND last_signal_at = \(fixture.base.now.addingTimeInterval(-7_200))") == 1)
    }
  }

  @Test("a verified CID with a different subject cannot authorize the retained recommendation")
  func recommendationHydrationRejectsChangedSubject() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      try await fixture.preseedItem()
      await fixture.verifier.set(.verified(try fixture.recommendation(subject: fixture.base.subject("other"))), for: fixture.sourceURI())
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      let journal = PostgresWireRecommendationJournal(pool: fixture.base.pool,
        logger: fixture.base.logger, dependencyVerificationEnabled: true)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(60), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_recommendation_dependency_recovery WHERE environment = \(fixture.base.environment) AND status = 'verified'") == 0)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.base.environment) AND event_kind = 'snapshot'") == 0)
    }
  }

  @Test("hydrating a missing document creates no author activity or artificial freshness")
  func recommendationHydrationPreservesActivity() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      try await fixture.preseedItem(alias: false)
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.subjectURI) AND canonical_key = \(fixture.key)") == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.subjectURI)") == 0)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_items WHERE canonical_key = \(fixture.key) AND NOT eligible AND last_signal_at = \(fixture.base.now.addingTimeInterval(-7_200))") == 1)
      let journal = PostgresWireRecommendationJournal(pool: fixture.base.pool,
        logger: fixture.base.logger, dependencyVerificationEnabled: true)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(60), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI()) AND occurred_at = \(fixture.base.now.addingTimeInterval(-3_600))") == 1)
    }
  }
}
