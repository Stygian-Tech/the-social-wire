import Foundation
import Logging
import PostgresNIO
import Testing

@testable import ThinAppViewCore

@Suite(
  "Postgres durable Jetstream V2 inbox",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil,
    "Set THIN_APPVIEW_TEST_DATABASE_URL to an explicitly disposable Postgres database."
  )
)
struct PostgresJetstreamInboxIntegrationTests {
  @Test("Postgres bulk read snapshots retain hidden URL duplicates and isolate viewer counters")
  func bulkReadSnapshotAndBatchMarks() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let viewer = "\(fixture.environment)-read-viewer"
      let otherViewer = "\(fixture.environment)-other-read-viewer"
      let author = "\(fixture.environment)-read-author"
      let publication = "at://\(author)/site.standard.publication/main"
      let now = Date()
      let cutoff = now.addingTimeInterval(-3_600)
      let oldIds = (0..<2).map { "at://\(author)/site.standard.document/old-\($0)" }
      let todayId = "at://\(author)/site.standard.document/today"
      let scope = AppViewUnreadCounterSupport.publicationScope(
        viewerDid: viewer, publicationId: publication, authorDid: author,
        publicationAtUri: publication, publicationScopeAtUris: [publication],
        publicationSiteUrls: [], sectionKeys: []
      )
      let otherScope = AppViewUnreadCounterSupport.publicationScope(
        viewerDid: otherViewer, publicationId: publication, authorDid: author,
        publicationAtUri: publication, publicationScopeAtUris: [publication],
        publicationSiteUrls: [], sectionKeys: []
      )
      let unreadScope = PublicationUnreadScope(
        publicationId: publication, authorDid: author, publicationAtUri: publication,
        publicationScopeAtUris: [publication], publicationSiteUrls: []
      )
      try await store.upsertPublicationScopes([scope, otherScope])
      for (index, id) in (oldIds + [todayId]).enumerated() {
        let publishedAt = id == todayId ? now : cutoff.addingTimeInterval(-60)
        try await store.upsertContentItem(IndexedContentItem(
          uri: id, cid: "fixture", authorDid: author, collection: "site.standard.document",
          createdAt: now.addingTimeInterval(Double(index)), indexedAt: now,
          publicationSite: publication,
          render: ContentRenderFields(
            title: id, publishedAt: ISO8601DateFormatter().string(from: publishedAt),
            articleUrl: "https://example.com/shared-story"
          ),
          expiresAt: now.addingTimeInterval(3_600)
        ))
      }
      try await store.markEntryUnread(viewerDid: viewer, subjectUri: oldIds[0], createdAt: now)
      _ = try await store.refreshUnreadCounters(viewerDid: viewer, scopes: [unreadScope])
      _ = try await store.refreshUnreadCounters(viewerDid: otherViewer, scopes: [unreadScope])
      let otherBefore = try await store.fetchUnreadCounters(
        viewerDid: otherViewer, publicationIds: [publication]
      )
      let presentation = try await store.listAggregateEntries(
        viewerDid: viewer, scopes: [scope], filter: .unread, cursor: nil, limit: 100
      )
      #expect(presentation.response.entries.map(\.entryId) == [todayId])

      var cursor: String?
      var snapshot: [AppViewEntryListItem] = []
      repeat {
        let page = try await store.listUnreadEntriesForReadMutation(
          viewerDid: viewer, scopes: [scope], cursor: cursor, limit: 1
        )
        snapshot.append(contentsOf: page.entries)
        cursor = page.cursor
      } while cursor != nil
      let selected = snapshot.filter { $0.publishedAt < cutoff }.map(\.entryId)
      #expect(Set(selected) == Set(oldIds))
      try await store.upsertReadMarks(viewerDid: viewer, subjectUris: selected + selected, createdAt: now)
      let dirty = try #require(try await store.fetchUnreadCounters(
        viewerDid: viewer, publicationIds: [publication]
      ).first)
      #expect(dirty.dirty)
      #expect(dirty.accuracy == .estimated)
      #expect(dirty.unreadCount == 3)
      #expect(try await store.fetchUnreadCounters(
        viewerDid: otherViewer, publicationIds: [publication]
      ) == otherBefore)
      #expect(try await store.hasReadMark(viewerDid: otherViewer, subjectUri: oldIds[0]) == false)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: todayId) == false)
      #expect(try await store.readBoundary(viewerDid: viewer, publicationId: publication) == nil)
      let remaining = try await store.listUnreadEntriesForReadMutation(
        viewerDid: viewer, scopes: [scope], cursor: nil, limit: 100
      )
      #expect(remaining.entries.map(\.entryId) == [todayId])
      let recounted = try #require(try await store.refreshUnreadCounters(
        viewerDid: viewer, scopes: [unreadScope]
      ).first)
      #expect(recounted.unreadCount == 1)
      #expect(!recounted.dirty)
      #expect(recounted.accuracy == .exact)
    }
  }

  @Test("Postgres resolves only proven terminal retired fatal-stream incidents")
  func resolvesOnlyTerminalRetiredGenerationIncidents() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      let retiredGeneration = "\(fixture.sourceGeneration)-retired"
      let incompleteGeneration = "\(fixture.sourceGeneration)-incomplete"
      let seamGapGeneration = "\(fixture.sourceGeneration)-seam-gap"
      let differentIdentityGeneration = "\(fixture.sourceGeneration)-different-identity"
      let reconciliationGeneration = "\(fixture.sourceGeneration)-reconciliation"
      try await fixture.seedCheckpoint(
        lastStagedSequence: 100, lastAppliedSequence: 100, at: now)
      try await fixture.seedIntakeLease(
        sourceGeneration: fixture.sourceGeneration,
        name: "wrong-intake-lease",
        expiresAt: now.addingTimeInterval(60),
        at: now)
      try await fixture.seedGenerationCheckpoint(
        sourceGeneration: retiredGeneration,
        lastStagedSequence: 50,
        lastAppliedSequence: 50,
        at: now)
      try await fixture.seedGenerationCheckpoint(
        sourceGeneration: incompleteGeneration,
        lastStagedSequence: 60,
        lastAppliedSequence: 59,
        at: now)
      try await fixture.seedGenerationCheckpoint(
        sourceGeneration: seamGapGeneration,
        lastStagedSequence: 0,
        lastAppliedSequence: 0,
        at: now)
      try await fixture.seedGenerationCheckpoint(
        sourceGeneration: differentIdentityGeneration,
        lastStagedSequence: 40,
        lastAppliedSequence: 40,
        sourceHost: "different.jetstream.invalid",
        at: now)
      try await fixture.seedGenerationCheckpoint(
        sourceGeneration: reconciliationGeneration,
        lastStagedSequence: 45,
        lastAppliedSequence: 45,
        at: now)
      try await fixture.seedReconciliationRequest(
        sourceGeneration: reconciliationGeneration, sequence: 45, status: "pending", at: now)
      try await fixture.seedIncident(
        id: "retired-fatal", sourceGeneration: retiredGeneration,
        category: "fatal_stream", status: "open", sequence: 50, at: now)
      try await fixture.seedIncident(
        id: "current-fatal", sourceGeneration: fixture.sourceGeneration,
        category: "fatal_stream", status: "open", sequence: 100, at: now)
      try await fixture.seedIncident(
        id: "incomplete-fatal", sourceGeneration: incompleteGeneration,
        category: "fatal_stream", status: "recovering", sequence: 60, at: now)
      try await fixture.seedIncident(
        id: "verification-required", sourceGeneration: retiredGeneration,
        category: "fatal_stream", status: "verification_required", sequence: 50, at: now)
      try await fixture.seedIncident(
        id: "retired-nonfatal", sourceGeneration: retiredGeneration,
        category: "transport_error", status: "open", sequence: 50, at: now)
      try await fixture.seedIncident(
        id: "seam-gap", sourceGeneration: seamGapGeneration,
        category: "fatal_stream", status: "open", sequence: 0, at: now)
      try await fixture.seedIncident(
        id: "different-identity", sourceGeneration: differentIdentityGeneration,
        category: "fatal_stream", status: "open", sequence: 40, at: now)
      try await fixture.seedIncident(
        id: "open-reconciliation", sourceGeneration: reconciliationGeneration,
        category: "fatal_stream", status: "open", sequence: 45, at: now)

      #expect(
        try await fixture.store.resolveTerminalRetiredGenerationIncidents(
          environment: fixture.environment,
          activeSourceGeneration: fixture.sourceGeneration,
          activeLeaseName: ThinAppViewConfig.defaultJetstreamLeaderLeaseName,
          at: now) == 0
      )
      try await fixture.seedIntakeLease(
        sourceGeneration: fixture.sourceGeneration,
        expiresAt: now.addingTimeInterval(60),
        at: now)

      #expect(
        try await fixture.store.resolveTerminalRetiredGenerationIncidents(
          environment: fixture.environment,
          activeSourceGeneration: fixture.sourceGeneration,
          at: now) == 1
      )
      let resolved = try await fixture.incidentEvidence(id: "retired-fatal")
      #expect(resolved.status == "resolved")
      #expect(resolved.recoveredThroughCursor == 50)
      #expect(resolved.evidence.contains("retired_generation_terminal"))
      #expect(resolved.evidence.contains("retired-generation-terminal-v1"))
      #expect(resolved.evidence.contains("identityAndInclusiveOverlapVerified"))
      #expect(try await fixture.incidentStatus(id: "current-fatal") == "open")
      #expect(try await fixture.incidentStatus(id: "incomplete-fatal") == "recovering")
      #expect(try await fixture.incidentStatus(id: "verification-required") == "verification_required")
      #expect(try await fixture.incidentStatus(id: "retired-nonfatal") == "open")
      #expect(try await fixture.incidentStatus(id: "seam-gap") == "open")
      #expect(try await fixture.incidentStatus(id: "different-identity") == "open")
      #expect(try await fixture.incidentStatus(id: "open-reconciliation") == "open")
      #expect(
        try await fixture.store.resolveTerminalRetiredGenerationIncidents(
          environment: fixture.environment,
          activeSourceGeneration: fixture.sourceGeneration,
          at: now) == 0
      )
    }
  }

  @Test("Postgres retired resolver enforces the terminal inbox allowlist")
  func retiredResolverTerminalInboxAllowlist() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(
        lastStagedSequence: 100, lastAppliedSequence: 100, at: now)
      try await fixture.seedIntakeLease(
        sourceGeneration: fixture.sourceGeneration,
        expiresAt: now.addingTimeInterval(60),
        at: now)
      let cases: [(generation: String, sequence: Int64, status: String, reconciled: Bool)] = [
        ("\(fixture.sourceGeneration)-pending-reconciled", 10, "pending", true),
        ("\(fixture.sourceGeneration)-retry-reconciled", 20, "retry", true),
        ("\(fixture.sourceGeneration)-dead-letter", 30, "dead_letter", false),
        ("\(fixture.sourceGeneration)-dead-letter-reconciled", 40, "dead_letter", true),
      ]
      for item in cases {
        try await fixture.seedGenerationCheckpoint(
          sourceGeneration: item.generation,
          lastStagedSequence: item.sequence,
          lastAppliedSequence: item.sequence,
          at: now)
        try await fixture.seedInbox(
          sequence: item.sequence,
          repoDid: "did:plc:terminal-\(item.sequence)",
          sourceGeneration: item.generation,
          trackedLifecycle: false,
          status: item.status,
          reconciledAt: item.reconciled ? now : nil,
          at: now)
        try await fixture.seedIncident(
          id: item.generation,
          sourceGeneration: item.generation,
          category: "fatal_stream",
          status: "open",
          sequence: item.sequence,
          at: now)
      }

      #expect(
        try await fixture.store.resolveTerminalRetiredGenerationIncidents(
          environment: fixture.environment,
          activeSourceGeneration: fixture.sourceGeneration,
          activeLeaseName: ThinAppViewConfig.defaultJetstreamLeaderLeaseName,
          at: now) == 1
      )
      #expect(
        try await fixture.incidentStatus(
          id: "\(fixture.sourceGeneration)-pending-reconciled") == "open"
      )
      #expect(
        try await fixture.incidentStatus(
          id: "\(fixture.sourceGeneration)-retry-reconciled") == "open"
      )
      #expect(
        try await fixture.incidentStatus(
          id: "\(fixture.sourceGeneration)-dead-letter") == "open"
      )
      #expect(
        try await fixture.incidentStatus(
          id: "\(fixture.sourceGeneration)-dead-letter-reconciled") == "resolved"
      )
    }
  }

  @Test("Postgres scope filter uses DB-current roles and records an explicit terminal state")
  func scopeFilterUsesCurrentRoles() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      let prefix = "did:plc:\(fixture.environment)"
      try await fixture.seedCheckpoint(lastStagedSequence: 5, at: now)
      try await fixture.seedAuthorScope(did: "\(prefix)-author-in", at: now)
      try await fixture.seedViewerScope(did: "\(prefix)-viewer-in", at: now)
      try await fixture.seedViewerScope(did: "\(prefix)-read-mark", at: now)
      try await fixture.seedInbox(
        sequence: 1, repoDid: "\(prefix)-author-out", eventKind: "commit",
        collection: "site.standard.document", at: now)
      try await fixture.seedInbox(
        sequence: 2, repoDid: "\(prefix)-author-in", eventKind: "commit",
        collection: "site.standard.entry", at: now)
      try await fixture.seedInbox(
        sequence: 3, repoDid: "\(prefix)-viewer-out", eventKind: "commit",
        collection: "app.skyreader.feed.subscription", at: now)
      try await fixture.seedInbox(
        sequence: 4, repoDid: "\(prefix)-viewer-in", eventKind: "commit",
        collection: "site.standard.graph.subscription", at: now)
      try await fixture.seedInbox(
        sequence: 5, repoDid: "\(prefix)-read-mark", eventKind: "commit",
        collection: "app.thesocialwire.entryReadState", at: now)

      let filtered = try await fixture.store.filterIngestionInboxOutsideScope(
        environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration,
        policy: AppViewIngestionScopePolicy.version,
        limit: 100,
        expiresAt: now.addingTimeInterval(3_600),
        at: now
      )
      let claimed = try await fixture.claim(workerId: "scope-worker", limit: 100, at: now)
      let evidence = try await fixture.filteredEvidence(sequence: 1)

      #expect(filtered == 3)
      #expect(claimed.map(\.sequence) == [2, 4])
      #expect(evidence.status == "filtered_scope")
      #expect(evidence.policy == AppViewIngestionScopePolicy.version)
      #expect(evidence.filteredAt != nil)
      #expect(evidence.appliedAt == nil)
      #expect(evidence.reconciledAt == nil)
      #expect(try await fixture.status(sequence: 3) == "filtered_scope")
      #expect(try await fixture.status(sequence: 5) == "filtered_scope")
    }
  }

  @Test("concurrent workers claim disjoint rows with SKIP LOCKED")
  func concurrentWorkersClaimDisjointRows() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 8, at: now)
      for sequence in Int64(1)...8 {
        try await fixture.seedInbox(
          sequence: sequence,
          repoDid: "did:plc:concurrent-\(sequence)",
          at: now
        )
      }

      let barrier = PostgresClaimBarrier()
      let firstClaim = Task {
        try await fixture.holdFirstClaimTransaction(
          sequences: Set(Int64(1)...Int64(4)),
          workerId: "worker-a",
          at: now,
          barrier: barrier
        )
      }
      await barrier.waitUntilLocked()

      let secondCompletion = PostgresClaimCompletion()
      let secondClaim = Task {
        do {
          let result = try await fixture.store.claimIngestionInbox(
            environment: fixture.environment,
            sourceGeneration: fixture.sourceGeneration,
            workerId: "worker-b",
            limit: 4,
            leaseUntil: now.addingTimeInterval(30),
            at: now
          )
          await secondCompletion.markComplete()
          return result
        } catch {
          await secondCompletion.markComplete()
          throw error
        }
      }
      let secondCompletedBeforeRelease = await Self.eventually {
        await secondCompletion.isComplete
      }
      await barrier.release()
      let second = try await secondClaim.value
      let first = try await firstClaim.value
      let firstSequences = Set(first)
      let secondSequences = Set(second.map(\.sequence))

      #expect(secondCompletedBeforeRelease)
      #expect(firstSequences.count == 4)
      #expect(secondSequences.count == 4)
      #expect(firstSequences.isDisjoint(with: secondSequences))
      #expect(firstSequences.union(secondSequences) == Set(Int64(1)...Int64(8)))
    }
  }

  private static func eventually(
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    for _ in 0..<100 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test("Postgres claims at most one FIFO event per repository")
  func claimsOneFIFOEventPerRepository() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 3, at: now)
      try await fixture.seedInbox(sequence: 1, repoDid: "did:plc:fifo", at: now)
      try await fixture.seedInbox(sequence: 2, repoDid: "did:plc:fifo", at: now)
      try await fixture.seedInbox(sequence: 3, repoDid: "did:plc:other", at: now)

      let first = try await fixture.claim(workerId: "fifo-worker", limit: 3, at: now)
      #expect(first.map(\.sequence) == [1, 3])
      guard let firstFIFO = first.first(where: { $0.sequence == 1 }) else {
        Issue.record("Expected the first FIFO row to be claimed")
        return
      }
      try await fixture.markApplied(firstFIFO, workerId: "fifo-worker", at: now)

      let second = try await fixture.claim(
        workerId: "fifo-worker",
        limit: 3,
        at: now.addingTimeInterval(1)
      )
      #expect(second.map(\.sequence) == [2])
    }
  }

  @Test("expired leases can be taken over and stale tokens stay fenced")
  func expiredLeaseTakeoverFencesStaleToken() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 10, at: now)
      try await fixture.seedInbox(
        sequence: 10,
        repoDid: "did:plc:takeover",
        status: "leased",
        leaseOwner: "old-worker",
        leaseToken: "old-token",
        leaseExpiresAt: now.addingTimeInterval(-1),
        at: now
      )

      let claimed = try await fixture.claim(workerId: "new-worker", limit: 1, at: now)
      #expect(claimed.map(\.sequence) == [10])
      let newLease = try #require(claimed.first)
      #expect(newLease.leaseToken != "old-token")

      await #expect(throws: AppViewIngestionInboxStoreError.staleLease) {
        try await fixture.store.markIngestionInboxApplied(
          environment: fixture.environment,
          sourceGeneration: fixture.sourceGeneration,
          sequence: 10,
          workerId: "old-worker",
          leaseToken: "old-token",
          expiresAt: now.addingTimeInterval(3_600),
          at: now
        )
      }
      try await fixture.store.renewIngestionInboxLease(
        environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration,
        sequence: 10,
        workerId: "new-worker",
        leaseToken: newLease.leaseToken,
        leaseUntil: now.addingTimeInterval(60),
        at: now
      )
      try await fixture.markApplied(newLease, workerId: "new-worker", at: now)
    }
  }

  @Test("watermark waits for the terminal prefix despite out-of-order completion")
  func watermarkAdvancesOnlyAcrossTerminalPrefix() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 30, at: now)
      for sequence in [Int64(10), 20, 30] {
        try await fixture.seedInbox(
          sequence: sequence,
          repoDid: "did:plc:watermark-\(sequence)",
          at: now
        )
      }
      let claimed = try await fixture.claim(workerId: "watermark-worker", limit: 3, at: now)
      let bySequence = Dictionary(uniqueKeysWithValues: claimed.map { ($0.sequence, $0) })

      try await fixture.markApplied(
        try #require(bySequence[30]),
        workerId: "watermark-worker",
        at: now
      )
      try await fixture.markApplied(
        try #require(bySequence[20]),
        workerId: "watermark-worker",
        at: now
      )
      try await fixture.store.advanceIngestionInboxAppliedWatermark(
        environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration,
        at: now
      )
      #expect(try await fixture.appliedWatermark() == nil)

      try await fixture.markApplied(
        try #require(bySequence[10]),
        workerId: "watermark-worker",
        at: now
      )
      try await fixture.store.advanceIngestionInboxAppliedWatermark(
        environment: fixture.environment,
        sourceGeneration: fixture.sourceGeneration,
        at: now.addingTimeInterval(1)
      )
      #expect(try await fixture.appliedWatermark() == 30)
    }
  }

  @Test("sixteen connections serve thirty-two logical claims and timely renewals")
  func sixteenConnectionPoolServesThirtyTwoLogicalWorkers() async throws {
    try await PostgresInboxFixture.withFixture(maximumConnections: 16) { fixture in
      let now = Date()
      try await fixture.seedCheckpoint(lastStagedSequence: 32, at: now)
      for sequence in Int64(1)...32 {
        try await fixture.seedInbox(
          sequence: sequence,
          repoDid: "did:plc:stress-\(sequence)",
          at: now
        )
      }

      let claimed = try await withThrowingTaskGroup(
        of: [StressLease].self,
        returning: [StressLease].self
      ) { group in
        for worker in 0..<32 {
          group.addTask {
            let workerId = "stress-worker-\(worker)"
            let items = try await fixture.store.claimIngestionInbox(
              environment: fixture.environment,
              sourceGeneration: fixture.sourceGeneration,
              workerId: workerId,
              limit: 1,
              leaseUntil: now.addingTimeInterval(30),
              at: now
            )
            return items.map { StressLease(workerId: workerId, item: $0) }
          }
        }
        var result: [StressLease] = []
        for try await batch in group { result.append(contentsOf: batch) }
        return result
      }
      #expect(claimed.count == 32)
      #expect(Set(claimed.map(\.item.sequence)).count == 32)

      let renewalStartedAt = Date()
      try await withThrowingTaskGroup(of: Void.self) { group in
        for lease in claimed {
          group.addTask {
            try await fixture.store.renewIngestionInboxLease(
              environment: fixture.environment,
              sourceGeneration: fixture.sourceGeneration,
              sequence: lease.item.sequence,
              workerId: lease.workerId,
              leaseToken: lease.item.leaseToken,
              leaseUntil: now.addingTimeInterval(90),
              at: Date()
            )
          }
        }
        try await group.waitForAll()
      }
      // Stay inside the production 20-second renewal interval without making hosted-runner
      // scheduling noise a flaky sub-second performance gate.
      #expect(Date().timeIntervalSince(renewalStartedAt) < 15)
    }
  }
}

private final class PostgresInboxFixture: @unchecked Sendable {
  static let testURL = ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"]

  let environment: String
  let sourceGeneration: String
  let store: PostgresThinAppViewStore

  private let pool: PostgresClient
  private let logger: Logger
  private let runTask: Task<Void, Never>

  private init(url: String, maximumConnections: Int) async throws {
    environment = "swift-integration-\(UUID().uuidString.lowercased())"
    sourceGeneration = "jetstream-integration-\(UUID().uuidString.lowercased())"
    logger = Logger(label: "postgres-inbox.integration")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = maximumConnections
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    self.pool = pool
    store = PostgresThinAppViewStore(pool: pool, logger: logger)
    runTask = Task { await pool.run() }
    await Task.yield()
    try await store.ping()
    try await installMinimalSchema()
  }

  static func withFixture(
    maximumConnections: Int = 4,
    _ body: @escaping @Sendable (PostgresInboxFixture) async throws -> Void
  ) async throws {
    guard let testURL else { return }
    let fixture = try await PostgresInboxFixture(
      url: testURL,
      maximumConnections: maximumConnections
    )
    do {
      try await body(fixture)
    } catch {
      await fixture.shutdown()
      throw error
    }
    await fixture.shutdown()
  }

  func claim(
    workerId: String,
    limit: Int,
    at now: Date
  ) async throws -> [AppViewIngestionInboxItem] {
    try await store.claimIngestionInbox(
      environment: environment,
      sourceGeneration: sourceGeneration,
      workerId: workerId,
      limit: limit,
      leaseUntil: now.addingTimeInterval(30),
      at: now
    )
  }

  func markApplied(
    _ item: AppViewIngestionInboxItem,
    workerId: String,
    at now: Date
  ) async throws {
    try await store.markIngestionInboxApplied(
      environment: environment,
      sourceGeneration: sourceGeneration,
      sequence: item.sequence,
      workerId: workerId,
      leaseToken: item.leaseToken,
      expiresAt: now.addingTimeInterval(3_600),
      at: now
    )
  }

  func seedCheckpoint(
    lastStagedSequence: Int64,
    lastAppliedSequence: Int64? = nil,
    replayAfterSequence: Int64? = 0,
    at now: Date
  ) async throws {
    let lastAppliedAt: Date? = lastAppliedSequence == nil ? nil : now
    try await execute(
      """
      INSERT INTO appview_jetstream_checkpoints
        (environment, source_generation, source_host, stream_nsid, filter_fingerprint,
         cursor_kind, last_staged_seq, last_staged_event_at, last_staged_at, replay_state,
         replay_after_seq,
         last_applied_seq, last_applied_event_at, last_applied_at, updated_at)
      VALUES
        (\(environment), \(sourceGeneration), 'integration.jetstream.invalid',
         'network.bsky.jetstream.subscribeEvents', 'integration-filter',
         'jetstream_v2_seq', \(lastStagedSequence), \(now), \(now), 'live',
         \(replayAfterSequence),
         \(lastAppliedSequence), \(lastAppliedAt), \(lastAppliedAt), \(now))
      """
    )
  }

  func seedGenerationCheckpoint(
    sourceGeneration: String,
    lastStagedSequence: Int64,
    lastAppliedSequence: Int64,
    sourceHost: String = "integration.jetstream.invalid",
    streamNSID: String = "network.bsky.jetstream.subscribeEvents",
    cursorKind: String = "jetstream_v2_seq",
    replayAfterSequence: Int64? = 0,
    at now: Date
  ) async throws {
    try await execute(
      """
      INSERT INTO appview_jetstream_checkpoints
        (environment, source_generation, source_host, stream_nsid, filter_fingerprint,
         cursor_kind, last_staged_seq, last_staged_event_at, last_staged_at,
         last_applied_seq, last_applied_event_at, last_applied_at, replay_state,
         replay_after_seq, updated_at)
      VALUES
        (\(environment), \(sourceGeneration), \(sourceHost),
         \(streamNSID), 'integration-filter',
         \(cursorKind), \(lastStagedSequence), \(now), \(now),
         \(lastAppliedSequence), \(now), \(now), 'live', \(replayAfterSequence), \(now))
      """
    )
  }

  func seedReconciliationRequest(
    sourceGeneration: String,
    sequence: Int64,
    status: String,
    at now: Date
  ) async throws {
    try await execute(
      """
      INSERT INTO appview_ingestion_reconciliation_requests
        (environment, id, source_generation, repo_did, status)
      VALUES (\(environment), \("\(sourceGeneration):\(sequence)"), \(sourceGeneration),
              'did:plc:reconciliation', \(status))
      """
    )
  }

  func seedIntakeLease(
    sourceGeneration: String,
    name: String = ThinAppViewConfig.defaultJetstreamLeaderLeaseName,
    expiresAt: Date,
    at now: Date
  ) async throws {
    try await execute(
      """
      INSERT INTO appview_ingestion_leases
        (environment, lease_name, source_generation, owner_id, fencing_token, acquired_at,
         lease_expires_at, released_at, updated_at)
      VALUES (\(environment), \(name), \(sourceGeneration),
              'integration-worker', 1, \(now), \(expiresAt), NULL, \(now))
      ON CONFLICT (environment, lease_name) DO UPDATE
      SET source_generation = EXCLUDED.source_generation,
          owner_id = EXCLUDED.owner_id,
          fencing_token = appview_ingestion_leases.fencing_token + 1,
          acquired_at = EXCLUDED.acquired_at,
          lease_expires_at = EXCLUDED.lease_expires_at,
          released_at = NULL,
          updated_at = EXCLUDED.updated_at
      """
    )
  }

  func seedIncident(
    id: String,
    sourceGeneration: String,
    category: String,
    status: String,
    sequence: Int64,
    at now: Date
  ) async throws {
    try await execute(
      """
      INSERT INTO appview_ingestion_incidents
        (environment, id, source_generation, source_host, source, cursor_kind,
         start_cursor, end_cursor, category, status, occurrence_count,
         first_detected_at, last_detected_at, last_error, replay_state,
         verification_evidence, updated_at, version)
      VALUES (\(environment), \(id), \(sourceGeneration), 'integration.jetstream.invalid',
              'jetstream-v2', 'jetstream_v2_seq', \(sequence), \(sequence), \(category),
              \(status), 1, \(now), \(now), 'TLS handshake timeout', 'live',
              '{}'::jsonb, \(now), 0)
      """
    )
  }

  func incidentStatus(id: String) async throws -> String? {
    let rows = try await pool.query(
      """
      SELECT status FROM appview_ingestion_incidents
      WHERE environment = \(environment) AND id = \(id)
      """,
      logger: logger
    )
    for try await row in rows { return try row.decode(String.self) }
    return nil
  }

  func incidentEvidence(
    id: String
  ) async throws -> (status: String, recoveredThroughCursor: Int64?, evidence: String) {
    let rows = try await pool.query(
      """
      SELECT status, recovered_through_cursor, verification_evidence::text
      FROM appview_ingestion_incidents
      WHERE environment = \(environment) AND id = \(id)
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode((String, Int64?, String).self)
    }
    throw AppViewIngestionInboxStoreError.invalidRow
  }

  func seedInbox(
    sequence: Int64,
    repoDid: String,
    sourceGeneration overrideSourceGeneration: String? = nil,
    eventKind: String = "identity",
    collection: String? = nil,
    trackedLifecycle: Bool = true,
    status: String = "pending",
    leaseOwner: String? = nil,
    leaseToken: String? = nil,
    leaseExpiresAt: Date? = nil,
    reconciledAt: Date? = nil,
    at now: Date
  ) async throws {
    if eventKind != "commit", trackedLifecycle {
      try await seedAuthorScope(did: repoDid, at: now)
    }
    let payload = "{}"
    let inboxSourceGeneration = overrideSourceGeneration ?? sourceGeneration
    try await execute(
      """
      INSERT INTO appview_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, payload, event_time, status, attempt_count, next_attempt_at, lease_owner, lease_token,
         lease_expires_at, staged_at, reconciled_at, updated_at)
      VALUES
        (\(environment), \(inboxSourceGeneration), \(sequence), 'integration.jetstream.invalid',
         'jetstream_v2_seq', \(eventKind), \(repoDid), \(collection), \(payload)::jsonb, \(now), \(status), 0,
         \(now), \(leaseOwner), \(leaseToken), \(leaseExpiresAt), \(now), \(reconciledAt), \(now))
      """
    )
  }

  func seedAuthorScope(did: String, at now: Date) async throws {
    try await execute(
      """
      INSERT INTO appview_publication_scopes
        (viewer_did, publication_id, author_did, publication_scope_at_uris,
         publication_site_urls, scope_keys, section_keys, updated_at)
      VALUES ('did:plc:integration-viewer', \("publication:\(did)"), \(did),
              '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, \(now))
      ON CONFLICT (viewer_did, publication_id) DO UPDATE
      SET author_did = EXCLUDED.author_did, updated_at = EXCLUDED.updated_at
      """
    )
  }

  func seedViewerScope(did: String, at now: Date) async throws {
    try await execute(
      """
      INSERT INTO appview_viewer_feeds (viewer_did, feed_kind, feed_id, updated_at)
      VALUES (\(did), 'subscribed', '', \(now))
      ON CONFLICT (viewer_did, feed_kind, feed_id) DO UPDATE
      SET updated_at = EXCLUDED.updated_at
      """
    )
  }

  func status(sequence: Int64) async throws -> String? {
    let rows = try await pool.query(
      """
      SELECT status FROM appview_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
        AND seq = \(sequence)
      """,
      logger: logger
    )
    for try await row in rows { return try row.decode(String.self) }
    return nil
  }

  func filteredEvidence(
    sequence: Int64
  ) async throws -> (status: String, policy: String?, filteredAt: Date?, appliedAt: Date?, reconciledAt: Date?) {
    let rows = try await pool.query(
      """
      SELECT status, filtered_scope_policy, filtered_scope_at, applied_at, reconciled_at
      FROM appview_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
        AND seq = \(sequence)
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode((String, String?, Date?, Date?, Date?).self)
    }
    throw AppViewIngestionInboxStoreError.invalidRow
  }

  func appliedWatermark() async throws -> Int64? {
    let rows = try await pool.query(
      """
      SELECT last_applied_seq
      FROM appview_jetstream_checkpoints
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode((Int64?).self)
    }
    return nil
  }

  func holdFirstClaimTransaction(
    sequences: Set<Int64>,
    workerId: String,
    at now: Date,
    barrier: PostgresClaimBarrier
  ) async throws -> [Int64] {
    let leaseToken = UUID().uuidString.lowercased()
    let sequenceList = sequences.sorted().map(String.init).joined(separator: ",")
    return try await pool.withTransaction(logger: logger) { connection in
      // sequenceList is derived solely from bounded Int64 test inputs. All external values
      // remain parameter-bound by PostgresQuery string interpolation.
      let lockQuery: PostgresQuery = """
        SELECT seq
        FROM appview_ingestion_inbox
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND seq IN (\(unescaped: sequenceList))
        ORDER BY seq
        FOR UPDATE
        """
      let rows = try await connection.query(
        lockQuery,
        logger: logger
      )
      var locked: [Int64] = []
      for try await row in rows { locked.append(try row.decode(Int64.self)) }
      let updateQuery: PostgresQuery = """
        UPDATE appview_ingestion_inbox
        SET status = 'leased', lease_owner = \(workerId), lease_token = \(leaseToken),
            lease_expires_at = \(now.addingTimeInterval(30)), updated_at = \(now)
        WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
          AND seq IN (\(unescaped: sequenceList))
        """
      let updated = try await connection.query(
        updateQuery,
        logger: logger
      )
      for try await _ in updated {}
      await barrier.markLockedAndWaitForRelease()
      return locked
    }
  }

  private func installMinimalSchema() async throws {
    let statements: [PostgresQuery] = [
      """
      CREATE TABLE IF NOT EXISTS content_items (
        uri TEXT PRIMARY KEY, cid TEXT NOT NULL, author_did TEXT NOT NULL,
        collection TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL,
        indexed_at TIMESTAMPTZ NOT NULL, publication_site TEXT,
        render_json JSONB NOT NULL, expires_at TIMESTAMPTZ NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS read_marks (
        viewer_did TEXT NOT NULL, subject_uri TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (viewer_did, subject_uri)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_unread_overrides (
        viewer_did TEXT NOT NULL, subject_uri TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (viewer_did, subject_uri)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_publication_read_floors (
        viewer_did TEXT NOT NULL, publication_id TEXT NOT NULL,
        read_floor_at TIMESTAMPTZ NOT NULL, read_floor_uri TEXT,
        generation BIGINT NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_unread_counters (
        viewer_did TEXT NOT NULL, publication_id TEXT NOT NULL,
        unread_count INTEGER NOT NULL CHECK (unread_count >= 0), generation BIGINT NOT NULL,
        accuracy TEXT NOT NULL CHECK (accuracy IN ('estimated', 'exact')),
        dirty BOOLEAN NOT NULL, counted_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_jetstream_checkpoints (
        environment TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        source_host TEXT NOT NULL,
        stream_nsid TEXT NOT NULL,
        filter_fingerprint TEXT NOT NULL,
        cursor_kind TEXT NOT NULL,
        last_staged_seq BIGINT,
        last_staged_event_at TIMESTAMPTZ,
        last_staged_at TIMESTAMPTZ,
        last_applied_seq BIGINT,
        last_applied_event_at TIMESTAMPTZ,
        last_applied_at TIMESTAMPTZ,
        replay_state TEXT NOT NULL DEFAULT 'idle',
        replay_after_seq BIGINT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (environment, source_generation)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_ingestion_inbox (
        environment TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        seq BIGINT NOT NULL,
        source_host TEXT NOT NULL,
        cursor_kind TEXT NOT NULL,
        event_kind TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        collection TEXT,
        operation TEXT,
        repo_rev TEXT,
        record_key TEXT,
        record_cid TEXT,
        payload JSONB NOT NULL,
        event_time TIMESTAMPTZ NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        lease_owner TEXT,
        lease_token TEXT,
        lease_expires_at TIMESTAMPTZ,
        failure_category TEXT,
        failure_reason TEXT,
        staged_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        applied_at TIMESTAMPTZ,
        dead_lettered_at TIMESTAMPTZ,
        reconciled_at TIMESTAMPTZ,
        filtered_scope_policy TEXT,
        filtered_scope_at TIMESTAMPTZ,
        expires_at TIMESTAMPTZ,
        PRIMARY KEY (environment, source_generation, seq)
      )
      """,
      """
      ALTER TABLE appview_ingestion_inbox
        ADD COLUMN IF NOT EXISTS filtered_scope_policy TEXT,
        ADD COLUMN IF NOT EXISTS filtered_scope_at TIMESTAMPTZ
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_publication_scopes (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        author_did TEXT NOT NULL,
        publication_at_uri TEXT,
        publication_scope_at_uris JSONB NOT NULL DEFAULT '[]'::jsonb,
        publication_site_urls JSONB NOT NULL DEFAULT '[]'::jsonb,
        scope_keys JSONB NOT NULL DEFAULT '[]'::jsonb,
        section_keys JSONB NOT NULL DEFAULT '[]'::jsonb,
        updated_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_viewer_feeds (
        viewer_did TEXT NOT NULL,
        feed_kind TEXT NOT NULL,
        feed_id TEXT NOT NULL DEFAULT '',
        updated_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (viewer_did, feed_kind, feed_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_ingestion_reconciliation_requests (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        repo_did TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        PRIMARY KEY (environment, id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_ingestion_leases (
        environment TEXT NOT NULL,
        lease_name TEXT NOT NULL,
        source_generation TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        fencing_token BIGINT NOT NULL,
        acquired_at TIMESTAMPTZ NOT NULL,
        lease_expires_at TIMESTAMPTZ NOT NULL,
        released_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ NOT NULL,
        PRIMARY KEY (environment, lease_name)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS appview_ingestion_incidents (
        environment TEXT NOT NULL,
        id TEXT NOT NULL,
        source_generation TEXT,
        source_host TEXT,
        source TEXT NOT NULL,
        cursor_kind TEXT NOT NULL,
        start_cursor BIGINT,
        end_cursor BIGINT,
        category TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'open',
        occurrence_count BIGINT NOT NULL DEFAULT 1,
        first_detected_at TIMESTAMPTZ NOT NULL,
        last_detected_at TIMESTAMPTZ NOT NULL,
        last_error TEXT,
        replay_state TEXT,
        replay_bytes_downloaded BIGINT NOT NULL DEFAULT 0,
        replay_retry_count INTEGER NOT NULL DEFAULT 0,
        replay_range_resume_count INTEGER NOT NULL DEFAULT 0,
        replay_sealed_seq BIGINT,
        recovered_through_cursor BIGINT,
        verification_evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
        resolved_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ NOT NULL,
        version INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (environment, id)
      )
      """,
    ]
    for statement in statements { try await execute(statement) }
  }

  private func execute(_ query: PostgresQuery) async throws {
    let rows = try await pool.query(query, logger: logger)
    for try await _ in rows {}
  }

  private func shutdown() async {
    let readViewers = ["\(environment)-read-viewer", "\(environment)-other-read-viewer"]
    try? await execute("DELETE FROM read_marks WHERE viewer_did = ANY(\(readViewers))")
    try? await execute("DELETE FROM appview_unread_overrides WHERE viewer_did = ANY(\(readViewers))")
    try? await execute("DELETE FROM appview_unread_counters WHERE viewer_did = ANY(\(readViewers))")
    try? await execute("DELETE FROM appview_publication_scopes WHERE viewer_did = ANY(\(readViewers))")
    try? await execute("DELETE FROM appview_publication_read_floors WHERE viewer_did = ANY(\(readViewers))")
    let readAuthor = "\(environment)-read-author"
    try? await execute("DELETE FROM content_items WHERE author_did = \(readAuthor)")
    try? await execute(
      """
      DELETE FROM appview_ingestion_incidents WHERE environment = \(environment)
      """
    )
    try? await execute(
      """
      DELETE FROM appview_ingestion_leases WHERE environment = \(environment)
      """
    )
    try? await execute(
      """
      DELETE FROM appview_ingestion_reconciliation_requests
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
      """
    )
    try? await execute(
      """
      DELETE FROM appview_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
      """
    )
    try? await execute(
      """
      DELETE FROM appview_jetstream_checkpoints
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
      """
    )
    runTask.cancel()
    await runTask.value
  }
}

private struct StressLease: Sendable {
  let workerId: String
  let item: AppViewIngestionInboxItem
}

private actor PostgresClaimBarrier {
  private var locked = false
  private var released = false
  private var lockWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilLocked() async {
    if locked { return }
    await withCheckedContinuation { lockWaiters.append($0) }
  }

  func markLockedAndWaitForRelease() async {
    locked = true
    let pendingLockWaiters = lockWaiters
    lockWaiters.removeAll()
    for waiter in pendingLockWaiters { waiter.resume() }
    if released { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func release() {
    released = true
    let pendingReleaseWaiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in pendingReleaseWaiters { waiter.resume() }
  }
}

private actor PostgresClaimCompletion {
  private(set) var isComplete = false

  func markComplete() {
    isComplete = true
  }
}
