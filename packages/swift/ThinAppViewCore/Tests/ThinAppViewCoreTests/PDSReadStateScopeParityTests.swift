import Foundation
import ReadStateCore
import Testing
@testable import ThinAppViewCore

extension PostgresJetstreamInboxIntegrationTests {
  @Test("overlapping legacy publications with different or absent floors cannot silently gain PDS authority", arguments: [true, false])
  func pdsMigrationRejectsAmbiguousScopeFloors(secondHasFloor: Bool) async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let store = fixture.store
      let viewer = "did:plc:" + fixture.sourceGeneration
      let author = viewer + "author"
      let site = "at://\(author)/site.standard.publication/shared"
      let ids = ["a", "b"].map { "at://\(author)/site.standard.publication/\($0)" }
      let scopes = ids.map { AppViewUnreadCounterSupport.publicationScope(viewerDid: viewer,
        publicationId: $0, authorDid: author, publicationAtUri: site,
        publicationScopeAtUris: [site], publicationSiteUrls: [], sectionKeys: []) }
      let unreadScopes = ids.map { PublicationUnreadScope(publicationId: $0, authorDid: author,
        publicationAtUri: site, publicationScopeAtUris: [site], publicationSiteUrls: []) }
      let now = Date().addingTimeInterval(-100)
      let uri = "at://\(author)/site.standard.document/item"
      try await store.upsertPublicationScopes(scopes)
      try await store.upsertContentItem(IndexedContentItem(uri: uri, cid: "fixture", authorDid: author,
        collection: "site.standard.document", createdAt: now, indexedAt: now,
        publicationSite: site, render: ContentRenderFields(title: "Overlap", publishedAt: "2026-09-08T00:00:00Z"),
        expiresAt: Date().addingTimeInterval(3600)))
      _ = try await store.markAllReadCounters(viewerDid: viewer, scopes: [unreadScopes[0]], readAt: now.addingTimeInterval(1))
      if secondHasFloor {
        _ = try await store.markAllReadCounters(viewerDid: viewer, scopes: [unreadScopes[1]], readAt: now.addingTimeInterval(-1))
      }
      #expect(try await store.listUnreadEntriesForReadMutation(viewerDid: viewer, scopes: [scopes[0]], cursor: nil, limit: 10).entries.isEmpty)
      #expect(try await store.listUnreadEntriesForReadMutation(viewerDid: viewer, scopes: [scopes[1]], cursor: nil, limit: 10).entries.map(\.entryId) == [uri])
      let exported = try await store.exportPDSReadStatePage(viewerDid: viewer, cursor: nil, expectedLegacyRevision: nil, limit: 10)
      let operations = try ReadStateMigrationPlanner.operations(rows: exported.rows, migrationId: "overlap")
      let projection = try ReadStateProjection(operations: operations, lastSequence: Int64(operations.count))
      // The portable subject state has no publication-view context and resolves this as read.
      #expect(projection.resolve(ReadStateSubject(uri: uri, authorDid: author, publicationSite: site, createdAt: now)).isRead)
      let manifest = ReadStateManifest(generation: "overlap", lastSequence: projection.lastSequence,
        head: ReadStateReference(uri: "at://\(viewer)/app.thesocialwire.readStateChunk/overlap", cid: "chunk"))
      await #expect(throws: PDSReadStateStorageError.legacyScopeOverlap) {
        try await store.activatePDSReadState(viewerDid: viewer, manifest: manifest, manifestCid: "manifest",
          projection: projection, expectedLegacyRevision: exported.legacyRevision)
      }
      #expect(try await store.pdsReadStateStatus(viewerDid: viewer).authority == .appview)
      #expect(try await store.listUnreadEntriesForReadMutation(viewerDid: viewer, scopes: [scopes[1]], cursor: nil, limit: 10).entries.map(\.entryId) == [uri])
      // An explicit legacy action aligning the scopes permits a new fenced export.
      _ = try await store.markAllReadCounters(viewerDid: viewer, scopes: [unreadScopes[1]], readAt: now.addingTimeInterval(1))
      let aligned = try await store.exportPDSReadStatePage(viewerDid: viewer, cursor: nil, expectedLegacyRevision: nil, limit: 10)
      let alignedOperations = try ReadStateMigrationPlanner.operations(rows: aligned.rows, migrationId: "aligned")
      let alignedProjection = try ReadStateProjection(operations: alignedOperations, lastSequence: Int64(alignedOperations.count))
      let alignedManifest = ReadStateManifest(generation: "aligned", lastSequence: alignedProjection.lastSequence, head: manifest.head)
      #expect(try await store.activatePDSReadState(viewerDid: viewer, manifest: alignedManifest, manifestCid: "aligned",
        projection: alignedProjection, expectedLegacyRevision: aligned.legacyRevision).authority == .pds)
      for scope in scopes {
        #expect(try await store.listUnreadEntriesForReadMutation(viewerDid: viewer, scopes: [scope], cursor: nil, limit: 10).entries.isEmpty)
      }
    }
  }
}
