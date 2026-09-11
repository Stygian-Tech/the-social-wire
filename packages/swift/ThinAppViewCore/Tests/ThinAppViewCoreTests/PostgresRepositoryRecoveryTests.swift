import Foundation
import Testing

@testable import ThinAppViewCore

@Suite("Postgres repository recovery", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil))
struct PostgresRepositoryRecoveryTests {
  @Test("page checkpoints survive replacement workers and enforce the owner lease")
  func durableProgressAndFencing() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let did = "did:plc:recovery-\(fixture.sourceGeneration)"
      let now = Date()
      try await fixture.seedInbox(sequence: 1, repoDid: did, eventKind: "sync", at: now)
      let item = try #require(try await fixture.claim(workerId: "first", limit: 1, at: now).first)
      let first = PDSRepositoryRecoveryContext(environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration, sequence: 1, repoDid: did,
        requestId: nil, workerId: "first", leaseToken: item.leaseToken)
      var state = try await fixture.store.loadRepositoryRecovery(first)
      state.collections["site.standard.document"] = .init(cursor: "next", seenCursors: ["next"],
        observedCount: 10, indexedCount: 10, complete: false)
      try await fixture.store.saveRepositoryRecovery(first, state: state,
        observedURIs: ["at://seen", "at://seen"], finish: false)
      try await fixture.store.yieldRepositoryRecovery(first)
      let secondItem = try #require(try await fixture.claim(workerId: "second", limit: 1,
        at: Date().addingTimeInterval(1)).first)
      #expect(secondItem.attemptCount == 0)
      let second = PDSRepositoryRecoveryContext(environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration, sequence: 1, repoDid: did,
        requestId: nil, workerId: "second", leaseToken: secondItem.leaseToken)
      let replacementStore = PostgresThinAppViewStore(pool: fixture.pool, logger: fixture.logger)
      let resumed = try await replacementStore.loadRepositoryRecovery(second)
      #expect(resumed.collections["site.standard.document"]?.cursor == "next")
      #expect(resumed.startedAt == state.startedAt)
      let staleState = state
      await #expect(throws: AppViewIngestionInboxStoreError.staleLease) {
        try await fixture.store.saveRepositoryRecovery(first, state: staleState,
          observedURIs: ["at://stale"], finish: false)
      }
      await #expect(throws: AppViewIngestionInboxStoreError.staleLease) {
        try await fixture.store.yieldRepositoryRecovery(first)
      }
      let rows = try await fixture.pool.query("""
        SELECT COUNT(*) FROM appview_repository_recovery_records
        WHERE environment = \(fixture.environment) AND source_generation = \(fixture.sourceGeneration)
        """, logger: fixture.logger)
      for try await row in rows { #expect(try row.decode(Int64.self) == 1) }
    }
  }

  @Test("bounded finalization retains observed and concurrent rows across cleanup slices")
  func boundedFinalization() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let did = "did:plc:prune-\(fixture.sourceGeneration)"
      let now = Date()
      try await fixture.seedInbox(sequence: 3, repoDid: did, eventKind: "sync", at: now)
      let item = try #require(try await fixture.claim(workerId: "worker", limit: 1, at: now).first)
      let context = PDSRepositoryRecoveryContext(environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration, sequence: 3, repoDid: did,
        requestId: nil, workerId: "worker", leaseToken: item.leaseToken)
      var state = try await fixture.store.loadRepositoryRecovery(context)
      for collection in ThinAppViewConfig.canonicalContentCollections {
        state.collections[collection] = .init(complete: true)
      }
      try await fixture.pool.query("""
        INSERT INTO content_items (uri, cid, author_did, collection, created_at, indexed_at,
          render_json, expires_at)
        SELECT \(fixture.sourceGeneration) || ':' || n::text, 'cid', \(did), 'site.standard.document',
          \(now.addingTimeInterval(-60)),
          CASE WHEN n = 2003 THEN \(now.addingTimeInterval(60)) ELSE \(now.addingTimeInterval(-60)) END,
          '{}'::jsonb, \(now.addingTimeInterval(3600)) FROM generate_series(1, 2003) n
        """, logger: fixture.logger)
      let observed = (1002...2002).map { fixture.sourceGeneration + ":" + String($0) }
      try await fixture.store.saveRepositoryRecovery(context, state: state, observedURIs: observed, finish: false)
      state = try await fixture.store.saveRepositoryRecovery(context, state: state, observedURIs: [], finish: true)
      #expect(!state.completed && !state.pruningComplete)
      state = try await fixture.store.saveRepositoryRecovery(context, state: state, observedURIs: [], finish: true)
      #expect(!state.completed)
      #expect(state.pruneURI != nil)
      for _ in 0..<5 {
        if state.completed { break }
        state = try await fixture.store.saveRepositoryRecovery(context, state: state, observedURIs: [], finish: true)
      }
      #expect(state.completed)
      try await fixture.store.saveRepositoryRecovery(context, state: state, observedURIs: [], finish: true)
      for try await row in try await fixture.pool.query(
        "SELECT COUNT(*) FROM content_items WHERE author_did = \(did)", logger: fixture.logger) {
        #expect(try row.decode(Int64.self) == 1002)
      }
      try await fixture.pool.query("DELETE FROM content_items WHERE author_did = \(did)", logger: fixture.logger)
    }
  }

  @Test("targeted reconciliation yields progress without exhausting its retry budget")
  func reconciliationProgress() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedReconciliationRequest(sourceGeneration: fixture.sourceGeneration,
        sequence: 7, status: "pending", at: now)
      let request = try #require(try await fixture.store.claimIngestionReconciliationRequests(
        environment: fixture.environment, sourceGeneration: fixture.sourceGeneration,
        workerId: "worker", limit: 1, leaseUntil: now.addingTimeInterval(60), at: now).first)
      let context = PDSRepositoryRecoveryContext(environment: request.environment,
        sourceGeneration: request.sourceGeneration, sequence: request.triggerSequence,
        repoDid: request.repoDid, requestId: request.id, workerId: "worker", leaseToken: request.leaseToken)
      let state = try await fixture.store.loadRepositoryRecovery(context)
      try await fixture.store.saveRepositoryRecovery(context, state: state,
        observedURIs: ["at://seen-request"], finish: false)
      try await fixture.store.yieldRepositoryRecovery(context)
      let claimed = try await fixture.store.claimIngestionReconciliationRequests(
        environment: fixture.environment, sourceGeneration: fixture.sourceGeneration,
        workerId: "next", limit: 1, leaseUntil: now.addingTimeInterval(60), at: now.addingTimeInterval(1))
      #expect(claimed.first?.attemptCount == 0)
      #expect(claimed.first?.id == request.id)
    }
  }
}
