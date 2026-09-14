import Foundation
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("a late verified job cannot postpone a replacement dependency lease")
  func dependencyRecoveryLateFailureCannotStealLease() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      let store = PostgresWireDependencyRecoveryStore(pool: fixture.base.pool,
        logger: fixture.base.logger, environment: fixture.base.environment)
      _ = try await store.seed(after: nil, asOf: fixture.base.now)
      let first = try #require(try await store.claim(asOf: fixture.base.now, limit: 1).first)
      #expect(try await store.observe(first, status: "verified", cid: fixture.cid,
        subject: fixture.subjectURI, revision: fixture.revision, observedAt: fixture.base.now,
        reason: nil, asOf: fixture.base.now))
      let later = fixture.base.now.addingTimeInterval(301)
      let replacement = try #require(try await store.claim(asOf: later, limit: 1).first)
      #expect(replacement.token != first.token)
      try await store.postpone(first, reason: "late prior network failure", asOf: later)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_recommendation_dependency_recovery
        WHERE environment = \(fixture.base.environment) AND status = 'leased'
          AND lease_token = \(replacement.token)
        """) == 1)
    }
  }

  @Test("a restarted recovery process waits for the durable lease and then reclaims its work")
  func dependencyRecoveryRestartsAfterLeaseExpiry() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      let original = PostgresWireDependencyRecoveryStore(pool: fixture.base.pool,
        logger: fixture.base.logger, environment: fixture.base.environment)
      _ = try await original.seed(after: nil, asOf: fixture.base.now)
      let first = try #require(try await original.claim(asOf: fixture.base.now, limit: 1).first)
      let restarted = PostgresWireDependencyRecoveryStore(pool: fixture.base.pool,
        logger: fixture.base.logger, environment: fixture.base.environment)
      #expect(try await restarted.claim(asOf: fixture.base.now.addingTimeInterval(1), limit: 1).isEmpty)
      let recovered = try #require(try await restarted.claim(asOf: fixture.base.now.addingTimeInterval(181), limit: 1).first)
      #expect(recovered.sourceURI == first.sourceURI)
      #expect(recovered.sequence == first.sequence)
      #expect(recovered.expectedCID == first.expectedCID)
      #expect(recovered.token != first.token)
      #expect(recovered.attempts == first.attempts + 1)
    }
  }

  @Test("terminal recommendation work cannot keep consuming dependency recovery slots")
  func dependencyRecoveryRetiresTerminalWork() async throws {
    try await WireRecommendationHydrationFixture.run { fixture in
      try await fixture.seed()
      let store = PostgresWireDependencyRecoveryStore(pool: fixture.base.pool,
        logger: fixture.base.logger, environment: fixture.base.environment)
      _ = try await store.seed(after: nil, asOf: fixture.base.now)
      try await fixture.base.pool.query(
        "UPDATE wire_recommendation_journal SET status = 'superseded' WHERE environment = \(fixture.base.environment)",
        logger: fixture.base.logger)
      #expect(try await store.claim(asOf: fixture.base.now, limit: 16).isEmpty)
      #expect(try await store.claim(asOf: fixture.base.now.addingTimeInterval(3_600), limit: 16).isEmpty)
    }
  }
}
