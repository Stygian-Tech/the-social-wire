import Foundation
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("retention removes a replay signal at exact expiry while preserving corpus and activity")
  func publicationReplaySignalRetentionBoundary() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let processAt = fixture.base.now.addingTimeInterval(60)
      let expiresAt = processAt.addingTimeInterval(1)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        title: "Recovered Corpus", operation: "create",
        occurredAt: expiresAt.addingTimeInterval(-WireDataPolicy.signalRetention))
      #expect(try await fixture.apply(sequence: 1) == .applied)
      let store = PostgresWireGenerationStore(pool: fixture.base.pool, logger: fixture.base.logger)
      try await store.deleteExpired(asOf: processAt, batchSize: 5000)
      #expect(try await fixture.signalCount() == 1)

      // This database-wide cleanup caused the cross-suite failure when the
      // generation tests advanced their own clock concurrently with replay.
      try await store.deleteExpired(asOf: expiresAt, batchSize: 5000)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.title() == "Recovered Corpus")
      #expect(try await fixture.projectionExists())
      #expect(try await fixture.actorSignals() == 1)
    }
  }

  @Test("publication replay keeps corpus and activity but omits signals at or beyond expiration",
    arguments: [-1.0, 0.0, 1.0])
  func publicationReplaySignalExpirationBoundary(remainingLifetime: Double) async throws {
    try await WireSourceVersionFixture.run { fixture in
      let processAt = fixture.base.now.addingTimeInterval(60)
      let originalTime = processAt.addingTimeInterval(-WireDataPolicy.signalRetention + remainingLifetime)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        title: "Recovered Corpus", operation: "create", occurredAt: originalTime)
      // A later pending event must remain available; expiry only suppresses the
      // disposable signal, never an inbox event or its durable projection.
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision,
        title: "Still Pending", occurredAt: processAt)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      #expect(try await fixture.title() == "Recovered Corpus")
      #expect(try await fixture.projectionExists())
      #expect(try await fixture.actorSignals() == 1)
      #expect(try await fixture.signalCount() == (remainingLifetime > 0 ? 1 : 0))
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_standard_record_fences
        WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI)
          AND repo_rev = \(WireSourceVersionFixture.olderRevision) AND activity_recorded
        """) == 1)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.base.environment) AND source_generation = 'live'
          AND seq = 2 AND status = 'pending'
        """) == 1)
    }
  }

  @Test("an expired same-version replay cannot invent fresh activity or rebuild an expired signal")
  func publicationReplayExpiredVersionRemainsIdempotent() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let originalTime = fixture.base.now.addingTimeInterval(-WireDataPolicy.signalRetention)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        operation: "create", occurredAt: originalTime)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      #expect(try await fixture.signalCount() == 0)
      let activity = try await fixture.actorSignals()
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        generation: "replay", occurredAt: fixture.base.now, sourceHost: "other-jetstream.example.test")
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .applied)
      #expect(try await fixture.projectionExists())
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.actorSignals() == activity)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_standard_record_fences
        WHERE environment = \(fixture.base.environment) AND source_uri = \(fixture.sourceURI)
          AND event_time = \(originalTime) AND activity_recorded
        """) == 1)
    }
  }

  @Test("expired older replay leaves a newer corpus version and its live signal untouched")
  func publicationReplayExpiredOlderVersionCannotRetractNewerSignal() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.newerRevision,
        title: "Current Corpus", operation: "create", occurredAt: fixture.base.now)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      let activity = try await fixture.actorSignals()
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        title: "Expired Old Corpus", operation: "create", generation: "replay",
        occurredAt: fixture.base.now.addingTimeInterval(-WireDataPolicy.signalRetention))
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .terminal)
      #expect(try await fixture.title() == "Current Corpus")
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.actorSignals() == activity)
    }
  }

  @Test("an expired publication replay still honors an inactive account fence")
  func publicationReplayExpirationDoesNotBypassAccountControls() async throws {
    try await WireSourceVersionFixture.run { fixture in
      try await fixture.insertAccount(sequence: 1, active: false, occurredAt: fixture.base.now)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        operation: "create", generation: "replay",
        occurredAt: fixture.base.now.addingTimeInterval(-WireDataPolicy.signalRetention))
      #expect(try await fixture.apply(sequence: 1, generation: "replay") == .terminal)
      #expect(try await fixture.projectionExists() == false)
      #expect(try await fixture.signalCount() == 0)
      #expect(try await fixture.actorSignals() == 0)
    }
  }
}
