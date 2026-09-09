import Foundation
import PostgresNIO
import ReadStateCore
import Testing

@testable import ThinAppViewCore

extension PostgresJetstreamInboxIntegrationTests {
  @Test("verified PDS generations preserve legacy export and every read query uses the latest applicable action")
  func pdsReadStateProjectionParityAndQueries() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let pool = fixture.pool
      let logger = fixture.logger
      let viewer = "did:plc:" + fixture.sourceGeneration
      let author = viewer + "author"
      let publication = "at://\(author)/site.standard.publication/main"
      let scope = PublicationUnreadScope(publicationId: publication, authorDid: author,
        publicationAtUri: publication, publicationScopeAtUris: [publication], publicationSiteUrls: [])
      let publicationScope = AppViewUnreadCounterSupport.publicationScope(viewerDid: viewer,
        publicationId: publication, authorDid: author, publicationAtUri: publication,
        publicationScopeAtUris: [publication], publicationSiteUrls: [], sectionKeys: [])
      let now = try ReadStateValidation.date("2026-09-08T12:00:00Z")
      let at = "2026-09-09T00:00:00Z"
      let ids = ["a", "b", "c"].map { "at://\(author)/site.standard.document/\($0)" }
      try await store.upsertPublicationScopes([publicationScope])
      for (index, uri) in ids.enumerated() {
        try await store.upsertContentItem(IndexedContentItem(uri: uri, cid: "cid", authorDid: author,
          collection: "site.standard.document", createdAt: now.addingTimeInterval(Double(index)),
          indexedAt: now, publicationSite: publication, render: ContentRenderFields(title: uri, publishedAt: at),
          expiresAt: Date().addingTimeInterval(86_400)))
      }
      let prepared = try await store.preparePDSReadStateBoundaries(viewerDid: viewer, scopes: [scope], at: now.addingTimeInterval(1))
      #expect(prepared.count == 1)
      #expect(prepared.first?.entryId == ids[1])
      _ = try await store.markAllReadCounters(viewerDid: viewer, scopes: [scope], readAt: now.addingTimeInterval(1))
      try await store.markEntryUnread(viewerDid: viewer, subjectUri: ids[0], createdAt: now.addingTimeInterval(2))
      var exported: [ReadStateLegacyRow] = []
      var cursor: String?
      var revision: Int64?
      repeat {
        let page = try await store.exportPDSReadStatePage(viewerDid: viewer, cursor: cursor,
          expectedLegacyRevision: revision, limit: 1)
        revision = page.legacyRevision
        exported += page.rows
        cursor = page.cursor
      } while cursor != nil
      #expect(exported.map(\.kind) == [.boundary, .unread])
      let baseline = try ReadStateMigrationPlanner.operations(rows: exported, migrationId: "fixture")
      let sequence = Int64(baseline.count)
      let manifest = ReadStateManifest(generation: "first", lastSequence: sequence,
        head: ReadStateReference(uri: "at://\(viewer)/app.thesocialwire.readStateChunk/one", cid: "chunk-one"))
      let state = try await store.activatePDSReadState(viewerDid: viewer, manifest: manifest,
        manifestCid: "manifest-one", projection: ReadStateProjection(operations: baseline, lastSequence: sequence),
        expectedLegacyRevision: revision)
      #expect(state.authority == .pds)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[0]) == false)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[1]) == true)
      let unread = try await store.listEntries(viewerDid: viewer, authorDid: author,
        publicationAtUri: publication, publicationScopeAtUris: [publication], publicationSiteUrls: [],
        filter: .unread, cursor: nil, limit: 100, readBoundary: nil)
      #expect(Set(unread.entries.map(\.entryId)) == Set([ids[0], ids[2]]))
      let mutationPage = try await store.listUnreadEntriesForReadMutation(
        viewerDid: viewer, scopes: [publicationScope], cursor: nil, limit: 1)
      #expect(mutationPage.entries.map(\.entryId) == [ids[2]])
      #expect(try await store.listUnreadEntriesForReadMutation(
        viewerDid: viewer, scopes: [publicationScope], cursor: mutationPage.cursor, limit: 1
      ).entries.map(\.entryId) == [ids[0]])
      #expect(try await store.countUnreadEntriesBatch(viewerDid: viewer, scopes: [scope])[publication] == 2)
      #expect(try await store.refreshUnreadCounters(viewerDid: viewer, scopes: [scope]).first?.unreadCount == 2)
      #expect(try await store.listFeedEntries(viewerDid: viewer, scopes: [scope], filter: .read,
        cursor: nil, limit: 100).entries.map(\.entryId) == [ids[1]])
      let all = try await store.listEntries(viewerDid: viewer, authorDid: author,
        publicationAtUri: publication, publicationScopeAtUris: [publication], publicationSiteUrls: [],
        filter: .all, cursor: nil, limit: 100, readBoundary: nil)
      let readStates = try await store.readStates(viewerDid: viewer, entries: all.entries)
      #expect(readStates == [ids[0]: false, ids[1]: true, ids[2]: false])
      #expect(try await store.hasReadMark(viewerDid: viewer + "other", subjectUri: ids[1]) == false)
      // The newest covering bulk read must override an earlier explicit unread.
      let allBoundary = ReadStateBoundary(scope: ReadStateScope(publicationId: publication,
        authorDid: author, publicationSiteKeys: [publication]), createdAt: at, entryId: nil)
      let later = baseline + [ReadStateOperation(actionId: "bulk-again", sequence: sequence + 1,
        state: .read, actedAt: at, boundaries: [allBoundary])]
      var priorTupleVersion: String?
      for try await row in try await pool.query("SELECT xmin::text FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer) AND subject_uri = \(ids[0])", logger: logger) {
        priorTupleVersion = try row.decode(String.self)
      }
      let next = ReadStateManifest(generation: "second", lastSequence: sequence + 1, head: manifest.head)
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: next, manifestCid: "manifest-two",
        projection: ReadStateProjection(operations: later, lastSequence: sequence + 1,
          sourceReferences: [try #require(manifest.head)]), expectedLegacyRevision: nil)
      for try await row in try await pool.query("SELECT xmin::text FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer) AND subject_uri = \(ids[0])", logger: logger) {
        #expect(try row.decode(String.self) == priorTupleVersion)
      }
      for try await row in try await pool.query("SELECT COUNT(*)::int FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer)", logger: logger) {
        #expect(try row.decode(Int.self) == 1)
      }
      #expect(try await store.countUnreadEntriesBatch(viewerDid: viewer, scopes: [scope])[publication] == 0)
      #expect(try await store.listUnreadEntriesForReadMutation(
        viewerDid: viewer, scopes: [publicationScope], cursor: nil, limit: 100).entries.isEmpty)
      // Two confirmations of different same-sequence forks cannot overwrite one another.
      do {
        _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: next, manifestCid: "stale-fork",
          projection: ReadStateProjection(operations: later, lastSequence: sequence + 1), expectedLegacyRevision: nil)
        Issue.record("A same-sequence fork replaced the active generation")
      } catch let error as PDSReadStateStorageError { #expect(error == .staleGeneration) }
      #expect(try await store.pdsReadStateStatus(viewerDid: viewer).manifestCid == "manifest-two")
      // A database failure midway through staging cannot publish a partial generation.
      try await pool.query("ALTER TABLE appview_pds_read_state_exact ADD CONSTRAINT tsw92_test_failure CHECK (is_read) NOT VALID", logger: logger)
      do {
        let failing = later + [ReadStateOperation(actionId: "failed", sequence: sequence + 2,
          state: .unread, actedAt: at, subjectUris: [ids[0]])]
        _ = try await store.activatePDSReadState(viewerDid: viewer,
          manifest: ReadStateManifest(generation: "failed", lastSequence: sequence + 2, head: manifest.head),
          manifestCid: "forced-failure", projection: ReadStateProjection(operations: failing, lastSequence: sequence + 2),
          expectedLegacyRevision: nil)
        Issue.record("The injected staging failure was not enforced")
      } catch {}
      try await pool.query("ALTER TABLE appview_pds_read_state_exact DROP CONSTRAINT tsw92_test_failure", logger: logger)
      #expect(try await store.pdsReadStateStatus(viewerDid: viewer).manifestCid == "manifest-two")
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[0]))
      // Retained source rows cannot accept an old client write after activation.
      do {
        try await store.markEntryUnread(viewerDid: viewer, subjectUri: ids[1], createdAt: Date())
        Issue.record("A legacy mutation changed an active PDS viewer")
      } catch {}
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[1]))
      // A clean projection rebuild marks the derived state unavailable first.
      try await pool.query("UPDATE appview_pds_read_state_authority SET projection_ready = FALSE WHERE viewer_did = \(viewer)", logger: logger)
      try await pool.query("DELETE FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer)", logger: logger)
      try await pool.query("DELETE FROM appview_pds_read_state_boundaries WHERE viewer_did = \(viewer)", logger: logger)
      _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: next, manifestCid: "manifest-two",
        projection: ReadStateProjection(operations: later, lastSequence: sequence + 1), expectedLegacyRevision: nil)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[0]))
      let replacement = [ReadStateOperation(actionId: "replacement", sequence: sequence + 2,
        state: .read, actedAt: at, subjectUris: [ids[0]])]
      _ = try await store.activatePDSReadState(viewerDid: viewer,
        manifest: ReadStateManifest(generation: "repacked", lastSequence: sequence + 2, head: manifest.head),
        manifestCid: "repacked", projection: ReadStateProjection(operations: replacement, lastSequence: sequence + 2),
        expectedLegacyRevision: nil)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[0]))
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[1]) == false)
      // The retained legacy floor must not hide PDS-unread rows after a verified repack.
      #expect(try await store.listUnreadEntriesForReadMutation(
        viewerDid: viewer, scopes: [publicationScope], cursor: nil, limit: 100
      ).entries.map(\.entryId) == [ids[2], ids[1]])
      try await pool.query("UPDATE appview_pds_read_state_authority SET projection_ready = FALSE WHERE viewer_did = \(viewer)", logger: logger)
      await #expect(throws: (any Error).self) {
        try await store.listUnreadEntriesForReadMutation(
          viewerDid: viewer, scopes: [publicationScope], cursor: nil, limit: 100)
      }
      for try await row in try await pool.query("SELECT COUNT(*)::int FROM appview_pds_read_state_boundaries WHERE viewer_did = \(viewer)", logger: logger) {
        #expect(try row.decode(Int.self) == 0)
      }
    }
  }

  @Test("read-state export revision and complete baseline gate prevent partial authority")
  func pdsReadStateRevisionAndParityFence() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let viewer = "did:plc:" + fixture.sourceGeneration
      let uri = "at://\(viewer)/site.standard.document/one"
      let now = Date()
      try await store.upsertReadMark(viewerDid: viewer, subjectUri: uri, createdAt: now)
      let exported = try await store.exportPDSReadStatePage(viewerDid: viewer, cursor: nil,
        expectedLegacyRevision: nil, limit: 1)
      try await store.upsertReadMark(viewerDid: viewer, subjectUri: uri + "two", createdAt: now)
      do {
        _ = try await store.exportPDSReadStatePage(viewerDid: viewer, cursor: nil,
          expectedLegacyRevision: exported.legacyRevision, limit: 100)
        Issue.record("Stale export revision was accepted")
      } catch let error as PDSReadStateStorageError {
        #expect(error == .revisionChanged)
      }
      let current = try await store.pdsReadStateStatus(viewerDid: viewer)
      let empty = ReadStateManifest(generation: "incomplete", lastSequence: 0, head: nil)
      do {
        _ = try await store.activatePDSReadState(viewerDid: viewer, manifest: empty,
          manifestCid: "empty", projection: ReadStateProjection(operations: [], lastSequence: 0),
          expectedLegacyRevision: current.legacyRevision)
        Issue.record("Partial baseline was activated")
      } catch let error as PDSReadStateStorageError {
        #expect(error == .parityMismatch)
      }
      #expect(try await store.pdsReadStateStatus(viewerDid: viewer).authority == .appview)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: uri))
    }
  }
  @Test("canonical boundaries preserve microsecond and bytewise ties, and later unread actions override read floors")
  func pdsReadStateMicrosecondAndUnreadBoundaryParity() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let viewer = "did:plc:" + fixture.sourceGeneration
      let author = viewer + "author"
      let at = "2026-09-08T12:00:00.123456Z"
      let ids = ["a", "b", "c"].map { "at://\(author)/site.standard.document/\($0)" }
      let date = try ReadStateValidation.date(at)
      for (index, id) in ids.enumerated() {
        try await store.upsertContentItem(IndexedContentItem(uri: id, cid: "cid", authorDid: author,
          collection: "site.standard.document", createdAt: date.addingTimeInterval(index == 2 ? 0.000001 : 0),
          indexedAt: date, publicationSite: "site", render: ContentRenderFields(title: id, publishedAt: at),
          expiresAt: Date().addingTimeInterval(86_400)))
      }
      let scope = ReadStateScope(publicationId: "publication", authorDid: author, publicationSiteKeys: ["site"])
      let operations = [
        ReadStateOperation(actionId: "read", sequence: 1, state: .read, actedAt: at,
          boundaries: [ReadStateBoundary(scope: scope, createdAt: at, entryId: ids[1])]),
        ReadStateOperation(actionId: "unread", sequence: 2, state: .unread, actedAt: at,
          boundaries: [ReadStateBoundary(scope: scope, createdAt: at, entryId: ids[0])])]
      #expect(try await store.previewPDSReadStateBoundaries(viewerDid: viewer,
        boundaries: [ReadStateBoundary(scope: scope, createdAt: at, entryId: ids[1])],
        subjectUris: ids + ["missing"]) == [ids[0], ids[1]])
      let projection = try ReadStateProjection(operations: operations, lastSequence: 2)
      _ = try await store.activatePDSReadState(viewerDid: viewer,
        manifest: ReadStateManifest(generation: "ties", lastSequence: 2,
          head: ReadStateReference(uri: "at://\(viewer)/app.thesocialwire.readStateChunk/one", cid: "one")),
        manifestCid: "ties", projection: projection, expectedLegacyRevision: 0)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[0]) == false)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[1]) == true)
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: ids[2]) == false)
    }
  }

  @Test("legacy read plans evaluate authority once instead of scanning projections per entry")
  func pdsReadStateLegacyQueryPlanRemainsBounded() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let viewer = "did:plc:" + fixture.sourceGeneration
      let rows = try await fixture.pool.query("""
        EXPLAIN (ANALYZE, FORMAT JSON)
        SELECT COUNT(*) FROM generate_series(1, 20000) candidate
        LEFT JOIN read_marks rm ON rm.viewer_did = \(viewer) AND rm.subject_uri = candidate::text
        LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = \(viewer) AND uo.subject_uri = candidate::text
        LEFT JOIN LATERAL appview_effective_entry_read_state(\(viewer), candidate::text,
          'author', 'site', NOW(), rm.subject_uri, uo.subject_uri) state ON TRUE
        WHERE state.read_uri IS NULL
        """, logger: fixture.logger)
      for try await row in rows {
        let json = try row.decode(String.self)
        let document = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        func inspect(_ plan: [String: Any]) {
          if plan["Relation Name"] as? String == "appview_pds_read_state_authority" {
            #expect((plan["Actual Loops"] as? Int ?? 0) <= 1)
          }
          #expect(plan["Function Name"] as? String != "appview_effective_entry_read_state")
          for child in plan["Plans"] as? [[String: Any]] ?? [] { inspect(child) }
        }
        inspect(try #require(document.first?["Plan"] as? [String: Any]))
      }
    }
  }

}
