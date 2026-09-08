import Foundation
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("resolved recommendation recovery rehydrates lost projections without recounting activity")
  func recommendationHydrationRestoresResolvedProjectionLoss() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      let original = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await original.hydrate(asOf: fixture.base.now, limit: 16)
      let journal = PostgresWireRecommendationJournal(pool: fixture.base.pool,
        logger: fixture.base.logger, dependencyVerificationEnabled: true)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(60), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.base.journalStatus(sequence: 1) == "resolved")
      #expect(try await fixture.signalCount() == 1)
      // Dropping this disposable projection also removes its alias and signal, as an unlogged reset can.
      try await fixture.base.pool.query("DELETE FROM wire_items WHERE canonical_key = \(fixture.key)", logger: fixture.base.logger)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(120), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.base.journalStatus(sequence: 1) == "pending")
      let restarted = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await restarted.hydrate(asOf: fixture.base.now.addingTimeInterval(121), limit: 16)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(180), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_active_actors
        WHERE actor_key_hash = (SELECT actor_key_hash FROM wire_recommendation_journal
          WHERE environment = \(fixture.base.environment) AND source_generation = 'live' AND seq = 1)
          AND public_signal_count = 1
        """) == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.subjectURI)") == 0)
    }
  }

  @Test("a new process re-verifies and rebuilds staged snapshots lost with the unlogged inbox")
  func recommendationHydrationRestoresMissingStagedInbox() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      let store = PostgresWireDependencyRecoveryStore(pool: fixture.base.pool,
        logger: fixture.base.logger, environment: fixture.base.environment)
      _ = try await store.seed(after: nil, asOf: fixture.base.now)
      let job = try #require(try await store.claim(asOf: fixture.base.now, limit: 1).first)
      #expect(try await store.observe(job, status: "verified", cid: fixture.cid,
        subject: fixture.subjectURI, revision: fixture.revision, observedAt: fixture.base.now,
        reason: nil, asOf: fixture.base.now))
      let staged = try await store.stage([try fixture.document()], for: job, asOf: fixture.base.now)
      #expect(staged.count == 1)
      // Reproduce loss of only this fixture's disposable rows; retain both logged recovery records.
      try await fixture.base.pool.query(
        "DELETE FROM wire_ingestion_inbox WHERE environment = \(fixture.base.environment)",
        logger: fixture.base.logger)
      let restartAt = fixture.base.now.addingTimeInterval(301)
      await fixture.verifier.set(.verified(try fixture.recommendation(observedAt: restartAt)), for: fixture.sourceURI())
      await fixture.verifier.set(.verified(try fixture.document(observedAt: restartAt)), for: fixture.subjectURI)
      let restarted = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await restarted.hydrate(asOf: restartAt, limit: 16)
      let journal = PostgresWireRecommendationJournal(pool: fixture.base.pool,
        logger: fixture.base.logger, dependencyVerificationEnabled: true)
      _ = try await journal.recover(asOf: restartAt.addingTimeInterval(30), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.subjectURI)") == 0)
    }
  }

  @Test("cancelled hydration retains the envelope and a new process safely resumes after lease expiry")
  func recommendationHydrationCancellationAndRestart() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      await fixture.verifier.setBeforeResponse { _ in throw CancellationError() }
      let interrupted = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      do {
        _ = try await interrupted.hydrate(asOf: fixture.base.now, limit: 16)
        Issue.record("Cancelled public verification must cancel the hydration batch")
      } catch is CancellationError {}
      #expect(try await fixture.base.journalStatus(sequence: 1) == "pending")
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.base.environment) AND event_kind = 'snapshot'") == 0)
      await fixture.verifier.setBeforeResponse { _ in }
      let restarted = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await restarted.hydrate(asOf: fixture.base.now.addingTimeInterval(181), limit: 16)
      let journal = PostgresWireRecommendationJournal(pool: fixture.base.pool,
        logger: fixture.base.logger, dependencyVerificationEnabled: true)
      _ = try await journal.recover(asOf: fixture.base.now.addingTimeInterval(200), limit: 16, sourceScope: fixture.scope)
      #expect(try await fixture.signalCount() == 1)
    }
  }

  @Test("account deactivation during public verification prevents dependency publication")
  func recommendationHydrationRechecksAccount() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      await fixture.verifier.setBeforeResponse { uri in
        guard uri == fixture.sourceURI() else { return }
        try await fixture.base.pool.query(
          """
          INSERT INTO wire_recommendation_account_fences
            (environment, repo_did, active, event_time, inactive_through, updated_at)
          VALUES (\(fixture.base.environment), \(fixture.readerDID), FALSE,
            \(fixture.base.now), \(fixture.base.now), \(fixture.base.now))
          """, logger: fixture.base.logger)
      }
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.base.environment) AND event_kind = 'snapshot'") == 0)
      #expect(try await fixture.signalCount() == 0)
    }
  }

  @Test("a replaced hydration lease cannot commit its public observation or staged snapshot")
  func recommendationHydrationRechecksLease() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      await fixture.verifier.setBeforeResponse { uri in
        guard uri == fixture.sourceURI() else { return }
        try await fixture.base.pool.query(
          """
          UPDATE wire_recommendation_dependency_recovery
          SET lease_token = gen_random_uuid()::text, lease_expires_at = \(fixture.base.now.addingTimeInterval(3_600))
          WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI())
          """, logger: fixture.base.logger)
      }
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_recommendation_dependency_recovery WHERE environment = \(fixture.base.environment) AND status = 'leased' AND lease_expires_at = \(fixture.base.now.addingTimeInterval(3_600))") == 1)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.base.environment) AND event_kind = 'snapshot'") == 0)
      #expect(try await fixture.signalCount() == 0)
    }
  }

  @Test("a recommendation superseded while public verification is in flight cannot stage its old dependency")
  func recommendationHydrationRechecksSource() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      await fixture.verifier.setBeforeResponse { uri in
        guard uri == fixture.sourceURI() else { return }
        try await fixture.base.pool.query(
          "UPDATE wire_recommendation_journal SET status = 'superseded' WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI())",
          logger: fixture.base.logger)
      }
      let hydrator = WireRecommendationHydrator(pool: fixture.base.pool, logger: fixture.base.logger,
        environment: fixture.base.environment, verifier: fixture.verifier, processor: try fixture.processor())
      _ = try await hydrator.hydrate(asOf: fixture.base.now, limit: 16)
      #expect(try await fixture.base.journalStatus(sequence: 1) == "superseded")
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.base.environment) AND event_kind = 'snapshot'") == 0)
      #expect(try await fixture.signalCount() == 0)
    }
  }
}
