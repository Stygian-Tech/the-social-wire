import AsyncHTTPClient
import Foundation
@preconcurrency import GRDB
import Logging
import NIOCore
import NIOHTTP1
import Testing

@testable import ThinAppViewCore

@Suite("Resumable repository recovery")
struct PDSRepositoryRecoveryTests {


  @Test("stolen leases cannot publish progress or yield the newer owner's work")
  func staleLeaseIsFenced() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    try await fixture.seedOwner()
    let old = try await fixture.claim(store: fixture.store)
    let newer = try await fixture.claim(store: fixture.store)
    let state = try await fixture.store.loadRepositoryRecovery(newer)
    await #expect(throws: AppViewIngestionInboxStoreError.staleLease) {
      try await fixture.store.saveRepositoryRecovery(old, state: state,
        observedURIs: ["at://stale"], finish: false)
    }
    await #expect(throws: AppViewIngestionInboxStoreError.staleLease) {
      try await fixture.store.yieldRepositoryRecovery(old)
    }
    #expect(try await fixture.scalar("SELECT COUNT(*) FROM appview_repository_recovery_records") == 0)
  }

  @Test("finalization is bounded, resumable and preserves observed and later rows")
  func boundedFinalizationPreservesContent() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    try await fixture.seedOwner()
    let context = try await fixture.claim(store: fixture.store)
    var state = try await fixture.store.loadRepositoryRecovery(context)
    for collection in ThinAppViewConfig.canonicalContentCollections {
      state.collections[collection] = .init(complete: true)
    }
    try await fixture.seedContent(prefix: "astale", count: 2_501, indexedAt: "2020-01-01T00:00:00Z")
    try await fixture.seedContent(prefix: "zseen", count: 1_101, indexedAt: "2020-01-01T00:00:00Z")
    try await fixture.seedContent(prefix: "later", count: 1, indexedAt: "2098-01-01T00:00:00Z")
    let observed = (0..<1_101).map { "at://\(fixture.did)/site.standard.document/zseen\($0)" }
    try await fixture.store.saveRepositoryRecovery(context, state: state, observedURIs: observed, finish: false)
    state = try await fixture.store.saveRepositoryRecovery(context, state: state, observedURIs: [], finish: true)
    #expect(!state.completed && !state.pruningComplete)
    // A full retained prefix still advances the traversal cursor without deleting or rescanning it.
    #expect(state.pruneURI?.contains("/zseen") == true)
    #expect(try await fixture.scalar("SELECT COUNT(*) FROM content_items") == 3_603)
    // Resume through a new store, including a separate URI cleanup phase larger than one batch.
    let replacement = try SQLiteThinAppViewStore(path: fixture.path, logger: fixture.logger)
    for _ in 0..<8 {
      state = try await replacement.loadRepositoryRecovery(context)
      if state.completed { break }
      state = try await replacement.saveRepositoryRecovery(context, state: state, observedURIs: [], finish: true)
    }
    #expect(state.completed && state.pruningComplete)
    #expect(try await fixture.scalar("SELECT COUNT(*) FROM content_items") == 1_102)
    #expect(try await fixture.scalar("SELECT COUNT(*) FROM appview_repository_recovery_records") == 0)
    // A crash after finalization but before the inbox terminal update must not prune a second time.
    try await replacement.saveRepositoryRecovery(context, state: state, observedURIs: [], finish: true)
    #expect(try await fixture.scalar("SELECT COUNT(*) FROM content_items") == 1_102)
  }


  @Test("owner cleanup cascades partial snapshot observations")
  func cleanupCascades() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    try await fixture.seedOwner()
    let context = try await fixture.claim(store: fixture.store)
    let state = try await fixture.store.loadRepositoryRecovery(context)
    try await fixture.store.saveRepositoryRecovery(context, state: state,
      observedURIs: ["at://seen"], finish: false)
    try await fixture.store.db.write { db in
      try db.execute(sql: "DELETE FROM appview_ingestion_inbox")
    }
    #expect(try await fixture.scalar("SELECT COUNT(*) FROM appview_repository_recovery_records") == 0)
  }
}

private struct RecoveryFixture {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID()).sqlite").path
  let logger = Logger(label: "repository.recovery.tests")
  let did = "did:plc:" + String((0..<24).map { _ in Array("abcdefghijklmnopqrstuvwxyz234567").randomElement()! })
  let store: SQLiteThinAppViewStore

  init() throws { store = try SQLiteThinAppViewStore(path: path, logger: logger) }
  func remove() { try? FileManager.default.removeItem(atPath: path) }

  func seedOwner() async throws {
    let did = did
    try await store.db.write { db in
      try db.execute(sql: """
        INSERT INTO appview_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, payload, event_time, status, next_attempt_at, staged_at, updated_at)
        VALUES ('test', 'generation', 1, 'test', 'jetstream_v2_seq', 'sync', ?, '{}',
          '2026-09-10T00:00:00.000Z', 'pending', '2026-09-10T00:00:00.000Z',
          '2026-09-10T00:00:00.000Z', '2026-09-10T00:00:00.000Z')
        """, arguments: [did])
    }
  }

  func claim(store: SQLiteThinAppViewStore) async throws -> PDSRepositoryRecoveryContext {
    let token = UUID().uuidString
    try await store.db.write { db in
      try db.execute(sql: """
        UPDATE appview_ingestion_inbox SET status = 'leased', lease_owner = 'worker',
          lease_token = ?, lease_expires_at = '2099-01-01T00:00:00.000Z'
        """, arguments: [token])
    }
    return .init(environment: "test", sourceGeneration: "generation", sequence: 1,
      repoDid: did, requestId: nil, workerId: "worker", leaseToken: token)
  }


  func seedContent(prefix: String, count: Int, indexedAt: String) async throws {
    let did = did
    try await store.db.write { db in
      for index in 0..<count {
        try db.execute(sql: """
          INSERT INTO content_items (uri, cid, author_did, collection, created_at, indexed_at,
            render_json, expires_at)
          VALUES (?, 'cid', ?, 'site.standard.document', '2020-01-01T00:00:00Z', ?, '{}',
            '2099-01-01T00:00:00Z')
          """, arguments: ["at://\(did)/site.standard.document/\(prefix)\(index)", did, indexedAt])
      }
    }
  }

  func scalar(_ sql: String) async throws -> Int {
    try await store.db.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
  }

  func currentState() async throws -> PDSRepositoryRecoveryState {
    let json = try await store.db.read { db in
      try String.fetchOne(db, sql: "SELECT recovery_state FROM appview_ingestion_inbox")!
    }
    return try JSONDecoder().decode(PDSRepositoryRecoveryState.self, from: Data(json.utf8))
  }
}
