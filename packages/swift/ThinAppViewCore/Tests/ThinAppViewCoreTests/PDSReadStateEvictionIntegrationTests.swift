import Foundation
import OperationsCore
import ReadStateCore
import Testing
@testable import ThinAppViewCore

extension PostgresJetstreamInboxIntegrationTests {
  @Test("idle eviction is bounded, preserves legacy sources, and excludes pending ingestion")
  func pdsIdleEvictionIsBoundedAndFenced() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let viewer = "did:plc:" + fixture.sourceGeneration
      let now = Date()
      let old = now.addingTimeInterval(-8 * 86_400)
      let ids = ["one", "two", "three"].map { "at://\(viewer)/site.standard.document/\($0)" }
      try await store.upsertReadMarks(viewerDid: viewer, subjectUris: ids, createdAt: old)
      let exported = try await store.exportPDSReadStatePage(viewerDid: viewer, cursor: nil, expectedLegacyRevision: nil, limit: 100)
      let operations = try ReadStateMigrationPlanner.operations(rows: exported.rows, migrationId: "evict")
      let manifest = ReadStateManifest(generation: "eviction", lastSequence: 3,
        head: ReadStateReference(uri: "at://\(viewer)/app.thesocialwire.readStateChunk/a", cid: "chunk"))
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: manifest, manifestCid: "manifest",
        projection: ReadStateProjection(operations: operations, lastSequence: 3), expectedLegacyRevision: exported.legacyRevision)
      try await fixture.pool.query("UPDATE appview_pds_read_state_authority SET last_accessed_at = \(old) WHERE viewer_did = \(viewer)", logger: fixture.logger)
      try await fixture.seedInbox(sequence: 1, repoDid: viewer, at: now)
      let pending = try await store.evictIdlePDSReadState(before: now.addingTimeInterval(-7 * 86_400), at: now, batchSize: 1)
      #expect(pending.viewerDid != viewer)
      #expect(try await store.pdsReadStateStatus(viewerDid: viewer).projectionReady)
      try await fixture.pool.query("DELETE FROM appview_ingestion_inbox WHERE repo_did = \(viewer)", logger: fixture.logger)
      let first = try await store.evictIdlePDSReadState(before: now.addingTimeInterval(-7 * 86_400), at: now, batchSize: 1)
      #expect(first.viewerDid == viewer)
      #expect(first.deletedRows == 1)
      #expect(try await !store.pdsReadStateStatus(viewerDid: viewer).projectionReady)
      await #expect(throws: (any Error).self) { try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[0]) }
      for try await row in try await fixture.pool.query("SELECT COUNT(*)::int FROM read_marks WHERE viewer_did = \(viewer)", logger: fixture.logger) {
        #expect(try row.decode(Int.self) == 3)
      }
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: manifest, manifestCid: "manifest",
        projection: ReadStateProjection(operations: operations, lastSequence: 3), expectedLegacyRevision: nil)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[0]))
      try await store.touchPDSReadStateAccess(viewerDid: viewer, at: now)
      var version: String?
      for try await row in try await fixture.pool.query("SELECT xmin::text FROM appview_pds_read_state_authority WHERE viewer_did = \(viewer)", logger: fixture.logger) { version = try row.decode(String.self) }
      try await store.touchPDSReadStateAccess(viewerDid: viewer, at: now.addingTimeInterval(1))
      for try await row in try await fixture.pool.query("SELECT xmin::text FROM appview_pds_read_state_authority WHERE viewer_did = \(viewer)", logger: fixture.logger) { #expect(try row.decode(String.self) == version) }
      #expect(try await store.evictIdlePDSReadState(before: now.addingTimeInterval(-7 * 86_400), at: now, batchSize: 1).viewerDid != viewer)
    }
  }

  @Test("evicted read state stays unavailable during PDS outage and complete CID verification restores parity")
  func pdsReadStateOutageRecoveryPreservesParity() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      typealias Records = PDSReadStateProjectorTests.Records
      let viewer = Records.viewer
      let store = fixture.store
      // This independently CID-verified fixture has a fixed publisher DID.
      for table in ["appview_pds_read_state_exact", "appview_pds_read_state_boundaries"] {
        try await fixture.pool.query("DELETE FROM \(unescaped: table) WHERE viewer_did = \(viewer)", logger: fixture.logger)
      }
      try await fixture.pool.query("UPDATE appview_pds_read_state_authority SET manifest = NULL, manifest_cid = NULL WHERE viewer_did = \(viewer)", logger: fixture.logger)
      try await fixture.pool.query("DELETE FROM read_marks WHERE viewer_did = \(viewer)", logger: fixture.logger)
      try await fixture.pool.query("DELETE FROM appview_pds_read_state_authority WHERE viewer_did = \(viewer)", logger: fixture.logger)
      let manifest = try JSONDecoder().decode(ReadStateManifest.self, from: Data(Records.manifest.utf8))
      let chunk = try JSONDecoder().decode(ReadStateChunk.self, from: Data(Records.chunk.utf8))
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: manifest, manifestCid: Records.manifestCID,
        projection: ReadStateProjection(operations: chunk.operations, lastSequence: 1), expectedLegacyRevision: 0)
      try await fixture.pool.query("UPDATE appview_pds_read_state_authority SET projection_ready = FALSE WHERE viewer_did = \(viewer)", logger: fixture.logger)
      try await fixture.pool.query("DELETE FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer)", logger: fixture.logger)
      let ops = PostgresOperationsStore(pool: fixture.pool, environment: fixture.sourceGeneration, logger: fixture.logger)
      let unavailable = Records(failure: .missingChunk)
      let badProjection = PDSReadStateProjector(store: store, fetchRecord: {
        try await unavailable.fetch(viewerDid: $0, collection: $1, key: $2, cid: $3)
      })
      let failed = PDSReadStateRecoveryCoordinator(store: store, operations: ops, logger: fixture.logger,
        retrySeconds: 0, rebuild: { try await badProjection.reconcile(viewerDid: $0) })
      await #expect(throws: PDSReadStateStorageError.projectionNotReady) { try await failed.requireReady(viewerDid: viewer) }
      await failed.waitForCurrentRebuild(viewerDid: viewer)
      #expect(try await !store.pdsReadStateStatus(viewerDid: viewer).projectionReady)
      await #expect(throws: (any Error).self) { try await store.hasReadMark(viewerDid: viewer, subjectUri: "x") }
      let remote = Records()
      let verified = PDSReadStateProjector(store: store, fetchRecord: {
        try await remote.fetch(viewerDid: $0, collection: $1, key: $2, cid: $3)
      })
      let recovery = PDSReadStateRecoveryCoordinator(store: store, operations: ops, logger: fixture.logger,
        rebuild: { try await verified.reconcile(viewerDid: $0) })
      await #expect(throws: PDSReadStateStorageError.projectionNotReady) { try await recovery.requireReady(viewerDid: viewer) }
      await recovery.waitForCurrentRebuild(viewerDid: viewer)
      try await recovery.requireReady(viewerDid: viewer)
      #expect(try await store.pdsReadStateStatus(viewerDid: viewer).projectionReady)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: "x"))
      #expect(await remote.requests == 3)
    }
  }
}

@Test func pdsReadStateEvictionRequiresExplicitSevenDayTrial() {
  #expect(!PDSReadStateEvictionConfiguration.fromEnvironment([:]).enabled)
  let trial = PDSReadStateEvictionConfiguration.fromEnvironment([
    "THIN_APPVIEW_PDS_READ_STATE_EVICTION_ENABLED": "true",
    "THIN_APPVIEW_PDS_READ_STATE_IDLE_DAYS": "1",
  ])
  #expect(trial.enabled)
  #expect(trial.idleSeconds == 7 * 86_400)
}

extension PostgresJetstreamInboxIntegrationTests {
  @Test("rebuilds are single-flight and occupy at most two durable slots across coordinators")
  func pdsRecoveryDistributedConcurrencyIsBounded() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let ops = PostgresOperationsStore(pool: fixture.pool, environment: fixture.sourceGeneration, logger: fixture.logger)
      let viewers = (0..<3).map { "did:plc:\(fixture.sourceGeneration)-\($0)" }
      let manifest = ReadStateManifest(generation: "empty", lastSequence: 0, head: nil)
      let projection = try ReadStateProjection(operations: [], lastSequence: 0)
      for viewer in viewers {
        _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: manifest, manifestCid: "empty",
          projection: projection, expectedLegacyRevision: 0)
        try await fixture.pool.query("UPDATE appview_pds_read_state_authority SET projection_ready = FALSE WHERE viewer_did = \(viewer)", logger: fixture.logger)
      }
      let gate = PDSRebuildConcurrencyGate()
      let coordinators = (0..<3).map { _ in PDSReadStateRecoveryCoordinator(store: store,
        operations: ops, logger: fixture.logger, retrySeconds: 0, rebuild: { viewer in
          await gate.enter(viewer)
          _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: manifest,
            manifestCid: "empty", projection: projection, expectedLegacyRevision: nil)
          await gate.leave()
          return true
        }) }
      for index in 0..<2 {
        await #expect(throws: PDSReadStateStorageError.projectionNotReady) {
          try await coordinators[index].requireReady(viewerDid: viewers[index])
        }
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while await gate.active < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      #expect(await gate.active == 2)
      await #expect(throws: PDSReadStateStorageError.projectionNotReady) { try await coordinators[0].requireReady(viewerDid: viewers[0]) }
      await #expect(throws: PDSReadStateStorageError.projectionNotReady) { try await coordinators[2].requireReady(viewerDid: viewers[2]) }
      await gate.open()
      for index in 0..<3 { await coordinators[index].waitForCurrentRebuild(viewerDid: viewers[index]) }
      #expect(await gate.maximumActive <= 2)
      #expect(await gate.calls[viewers[0]] == 1)
      #expect(try await store.pdsReadStateStatus(viewerDid: viewers[0]).projectionReady)
      #expect(try await store.pdsReadStateStatus(viewerDid: viewers[1]).projectionReady)
    }
  }

  @Test("a stalled PDS rebuild times out, releases durable leases, and stays unavailable")
  func pdsRecoveryDeadlineRetainsUnavailableState() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let viewer = "did:plc:" + fixture.sourceGeneration
      let manifest = ReadStateManifest(generation: "empty", lastSequence: 0, head: nil)
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: manifest, manifestCid: "empty",
        projection: ReadStateProjection(operations: [], lastSequence: 0), expectedLegacyRevision: 0)
      try await fixture.pool.query("UPDATE appview_pds_read_state_authority SET projection_ready = FALSE WHERE viewer_did = \(viewer)", logger: fixture.logger)
      let ops = PostgresOperationsStore(pool: fixture.pool, environment: fixture.sourceGeneration, logger: fixture.logger)
      let recovery = PDSReadStateRecoveryCoordinator(store: store, operations: ops, logger: fixture.logger,
        deadlineSeconds: 0.05, rebuild: { _ in try await Task.sleep(for: .seconds(10)); return true })
      await #expect(throws: PDSReadStateStorageError.projectionNotReady) { try await recovery.requireReady(viewerDid: viewer) }
      await recovery.waitForCurrentRebuild(viewerDid: viewer)
      #expect(try await !store.pdsReadStateStatus(viewerDid: viewer).projectionReady)
      for try await row in try await fixture.pool.query("SELECT COUNT(*)::int FROM appview_ingestion_leases WHERE environment = \(fixture.sourceGeneration) AND released_at IS NULL", logger: fixture.logger) {
        #expect(try row.decode(Int.self) == 0)
      }
    }
  }
}

private actor PDSRebuildConcurrencyGate {
  var active = 0
  var maximumActive = 0
  var calls: [String: Int] = [:]
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func enter(_ viewer: String) async {
    active += 1
    maximumActive = max(maximumActive, active)
    calls[viewer, default: 0] += 1
    if !opened { await withCheckedContinuation { waiters.append($0) } }
  }
  func leave() { active -= 1 }
  func open() {
    opened = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}
