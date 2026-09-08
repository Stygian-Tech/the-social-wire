import Foundation
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("a retained retry promotes an existing pending journal row to require verification")
  func recommendationHydrationPromotesLegacyPendingRetry() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      try await fixture.preseedItem()
      try await fixture.base.pool.query(
        "UPDATE wire_recommendation_journal SET dependency_verification_required = FALSE WHERE environment = \(fixture.base.environment)",
        logger: fixture.base.logger)
      try await fixture.base.pool.query(
        "UPDATE wire_ingestion_inbox SET status = 'pending', attempt_count = 8 WHERE environment = \(fixture.base.environment)",
        logger: fixture.base.logger)
      let claimed = try #require(try await fixture.processor().claimNext(
        in: .init(environment: fixture.base.environment, sourceGeneration: "live", repoDID: fixture.readerDID),
        asOf: fixture.base.now))
      #expect(claimed.attemptCount == 9)
      #expect(try await fixture.processor().applyClaimed(claimed, asOf: fixture.base.now) == .deferred)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_recommendation_journal WHERE environment = \(fixture.base.environment) AND status = 'pending' AND dependency_verification_required") == 1)
    }
  }

  @Test("retained retries require their own proof while a fresh first claim keeps the alias fast path",
    arguments: [0, 8])
  func recommendationHydrationFencesRetriedOriginal(priorAttempts: Int) async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.preseedItem()
      let original = try fixture.recommendation()
      let record = try JSONSerialization.jsonObject(with: original.recordJSON)
      let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
        "commit": ["rev": fixture.revision, "record": record] as [String: Any],
      ]), as: UTF8.self)
      let originalTime = fixture.base.now.addingTimeInterval(-3_600)
      let deadLetterAt: Date? = priorAttempts > 0 ? fixture.base.now : nil
      try await fixture.base.pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
           collection, operation, repo_rev, record_cid, record_key, payload, event_time,
           next_attempt_at, status, attempt_count, dead_lettered_at)
        VALUES (\(fixture.base.environment), 'live', 1, 'jetstream.example.test', 'jetstream_v2_seq', 'commit',
          \(fixture.readerDID), 'site.standard.graph.recommend', 'create', \(fixture.revision), \(fixture.cid),
          'recommendation-1', \(payload)::jsonb, \(originalTime), \(fixture.base.now),
          \(priorAttempts == 0 ? "pending" : "dead_letter"), \(priorAttempts), \(deadLetterAt))
        """, logger: fixture.base.logger)
      if priorAttempts > 0 {
        // Requeue only the retained original; preserve its accumulated durable attempts.
        try await fixture.base.pool.query(
          "UPDATE wire_ingestion_inbox SET status = 'pending', dead_lettered_at = NULL WHERE environment = \(fixture.base.environment)",
          logger: fixture.base.logger)
      }
      let claimed = try #require(try await fixture.processor().claimNext(
        in: .init(environment: fixture.base.environment, sourceGeneration: "live", repoDID: fixture.readerDID),
        asOf: fixture.base.now))
      #expect(claimed.attemptCount == priorAttempts + 1)
      // The processor must consult the locked row, not a caller-supplied first-attempt claim.
      let spoofed = WireInboxEvent(environment: claimed.environment, sourceGeneration: claimed.sourceGeneration,
        sequence: claimed.sequence, sourceHost: claimed.sourceHost, cursorKind: claimed.cursorKind,
        eventKind: claimed.eventKind, repoDID: claimed.repoDID, collection: claimed.collection,
        operation: claimed.operation, recordKey: claimed.recordKey, payloadJSON: claimed.payloadJSON,
        eventTime: claimed.eventTime, leaseToken: claimed.leaseToken, attemptCount: 1)
      let outcome = try await fixture.processor().applyClaimed(spoofed, asOf: fixture.base.now)
      #expect(outcome == (priorAttempts == 0 ? .applied : .deferred))
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_journal
        WHERE environment = \(fixture.base.environment)
          AND dependency_verification_required = \(priorAttempts > 0)
        """) == 1)
      if priorAttempts == 0 {
        #expect(try await fixture.signalCount() == 1)
        #expect(await fixture.verifier.calls().isEmpty)
        try await fixture.base.pool.query(
          "UPDATE wire_ingestion_inbox SET status = 'pending', applied_at = NULL, attempt_count = 8 WHERE environment = \(fixture.base.environment)",
          logger: fixture.base.logger)
        let replay = try #require(try await fixture.processor().claimNext(
          in: .init(environment: fixture.base.environment, sourceGeneration: "live", repoDID: fixture.readerDID),
          asOf: fixture.base.now))
        #expect(replay.attemptCount == 9)
        #expect(try await fixture.processor().applyClaimed(replay, asOf: fixture.base.now) == .applied)
        #expect(try await fixture.base.scalar(
          """
          SELECT COUNT(*)::bigint FROM wire_recommendation_journal
          WHERE environment = \(fixture.base.environment) AND status = 'resolved'
            AND NOT dependency_verification_required AND actor_recorded
            AND event_time = \(originalTime) AND record_cid = \(fixture.cid) AND repo_rev = \(fixture.revision)
          """) == 1)
        #expect(try await fixture.base.scalar(
          "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI()) AND occurred_at = \(originalTime)") == 1)
        #expect(try await fixture.base.scalar(
          """
          SELECT COUNT(*)::bigint FROM wire_active_actors WHERE public_signal_count = 1
            AND actor_key_hash = (SELECT actor_key_hash FROM wire_recommendation_journal
              WHERE environment = \(fixture.base.environment) AND source_generation = 'live' AND seq = 1)
          """) == 1)
        return
      }
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.base.journalStatus(sequence: 1) == "pending")
      await fixture.verifier.set(.verified(original), for: fixture.sourceURI())
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      let journal = PostgresWireRecommendationJournal(pool: fixture.base.pool,
        logger: fixture.base.logger, dependencyVerificationEnabled: true)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(60), limit: 16, sourceScope: fixture.scope)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(61), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.sourceURI()) AND occurred_at = \(originalTime)") == 1)
      let calls = await fixture.verifier.calls()
      #expect(calls.count == 1)
      #expect(calls.first?.expectedCID == fixture.cid)
    }
  }

  @Test("missing or inactive subjects retain a typed retry without treating the recommendation as withdrawn",
    arguments: ["subject_record_absent", "subject_repo_inactive"])
  func recommendationHydrationRetainsSubjectFailure(reason: String) async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      let observation = WirePublicRecordObservation(uri: fixture.subjectURI, expectedCID: nil,
        repositoryRevision: fixture.revision, pdsBase: "https://pds.publisher.social", observedAt: fixture.base.now)
      await fixture.verifier.set(reason == "subject_record_absent" ? .missing(observation) : .inactive(observation),
        for: fixture.subjectURI)
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      let result = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      #expect(result.verified == 1)
      #expect(result.staged == 0)
      #expect(result.unavailable == 1)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_dependency_recovery
        WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI())
          AND status = 'unavailable' AND failure_reason = \(reason)
          AND next_attempt_at > \(fixture.base.now.addingTimeInterval(1)) AND lease_token IS NULL
        """) == 1)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_journal
        WHERE environment = \(fixture.base.environment) AND status = 'pending' AND operation = 'create'
          AND record_cid = \(fixture.cid) AND payload->'commit'->'record'->>'document' = \(fixture.subjectURI)
        """) == 1)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.base.environment) AND (status = 'applied' OR operation = 'delete' OR event_kind = 'snapshot')
        """) == 0)
      #expect(try await fixture.signalCount() == 0)
    }
  }

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
