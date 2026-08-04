import AsyncHTTPClient
import Foundation
import GatewayCore
import Logging
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Aggregate feed projection cache")
struct PublicationProjectionAggregateFeedCacheTests {
  @Test("uses cached folder membership without live discovery")
  func cachedFolderMembership() async throws {
    let logger = Logger(label: "aggregate-feed-projection.test")
    let storePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("aggregate-feed-store-\(UUID().uuidString).sqlite").path
    let cachePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("aggregate-feed-cache-\(UUID().uuidString).sqlite").path
    defer {
      try? FileManager.default.removeItem(atPath: storePath)
      try? FileManager.default.removeItem(atPath: cachePath)
    }

    let store = try SQLiteThinAppViewStore(path: storePath, logger: logger)
    let cache = try SQLiteAppViewProjectionCacheStore(path: cachePath, logger: logger)
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let viewerDid = "did:plc:viewer"
    let row = publication(id: "at://did:plc:writer/site.standard.publication/main")
    let priority = PublicationSidebarResponse(
      viewerDid: viewerDid,
      folders: [],
      publicationPrefs: [],
      folderSections: [],
      allPublicationRows: [],
      myPublications: [],
      subscribedUnfoldered: [],
      followingTabPublications: [],
      enrollAuthorDids: [],
      totalUnreadCount: 0,
      refreshedAt: Date()
    )
    let snapshot = BootstrapSidebarCacheSnapshot(
      priority: priority,
      folderPayload: AppViewBootstrapSidebarFoldersPayload(
        folderSections: [
          PublicationFolderSection(
            folderUri: "at://\(viewerDid)/app.thesocialwire.folder/news",
            folderRkey: "news",
            name: "News",
            publications: [row],
            unreadCount: 0
          )
        ],
        allPublicationRows: [row]
      )
    )
    let json = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!
    try await cache.storeSidebarProjectionJSON(
      viewerDid: viewerDid,
      jsonBody: json,
      expiresAt: Date().addingTimeInterval(-60)
    )

    let service = PublicationProjectionService(
      httpClient: client,
      plcURL: "http://127.0.0.1:1",
      logger: logger,
      thinStore: store,
      projectionCache: cache
    )
    #expect(await service.rebuildFeedProjectionFromCachedSidebar(viewerDid: viewerDid))
    let folder = try await store.listFeedEntries(
      viewerDid: viewerDid,
      selector: AppViewFeedSelector(kind: .folder, id: "news"),
      filter: .all,
      cursor: nil,
      limit: 50
    )
    #expect(folder != nil)
    let publication = try await store.listFeedEntries(
      viewerDid: viewerDid,
      selector: AppViewFeedSelector(kind: .publication, id: row.publicationId),
      filter: .all,
      cursor: nil,
      limit: 50
    )
    #expect(publication != nil)
    try await client.shutdown()
  }

  @Test("unread-count lookups for a cold in-memory cache resolve from the durable sidebar cache")
  func unreadCountsFallBackToDurableCacheBeforeLiveDiscovery() async throws {
    let logger = Logger(label: "unread-counts-cache.test")
    let storePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("unread-counts-store-\(UUID().uuidString).sqlite").path
    let cachePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("unread-counts-cache-\(UUID().uuidString).sqlite").path
    defer {
      try? FileManager.default.removeItem(atPath: storePath)
      try? FileManager.default.removeItem(atPath: cachePath)
    }

    let store = try SQLiteThinAppViewStore(path: storePath, logger: logger)
    let cache = try SQLiteAppViewProjectionCacheStore(path: cachePath, logger: logger)
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let viewerDid = "did:plc:viewer"
    let row = publication(id: "at://did:plc:writer/site.standard.publication/main")
    let priority = PublicationSidebarResponse(
      viewerDid: viewerDid,
      folders: [],
      publicationPrefs: [],
      folderSections: [],
      allPublicationRows: [row],
      myPublications: [],
      subscribedUnfoldered: [row],
      followingTabPublications: [],
      enrollAuthorDids: [],
      totalUnreadCount: 0,
      refreshedAt: Date()
    )
    let snapshot = BootstrapSidebarCacheSnapshot(priority: priority, folderPayload: nil)
    let json = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!
    try await cache.storeSidebarProjectionJSON(
      viewerDid: viewerDid,
      jsonBody: json,
      expiresAt: Date().addingTimeInterval(-60)
    )

    let projectionService = PublicationProjectionService(
      httpClient: client,
      // Deliberately unroutable: if the fix regresses and falls through to a live
      // discovery pass, this call would hang/fail instead of resolving instantly from
      // the durable cache above.
      plcURL: "http://127.0.0.1:1",
      logger: logger,
      thinStore: store,
      projectionCache: cache
    )
    let readService = ThinAppViewReadService(
      store: store,
      projectionCache: cache,
      logger: logger
    )

    let response = try await readService.unreadCountsByPublicationIds(
      auth: AuthContext(
        did: viewerDid,
        authorizationForwardingValue: "DPoP token",
        dpopProof: "proof"
      ),
      publicationIds: [row.publicationId],
      projectionService: projectionService
    )

    #expect(response.counts[row.publicationId] == 0)
    try await client.shutdown()
  }

  private func publication(id: String) -> SidebarPublicationRow {
    let authorDid = String(id.split(separator: "/")[2])
    return SidebarPublicationRow(
      publicationId: id,
      subscriptionPublicationId: nil,
      authorDid: authorDid,
      authorHandle: nil,
      title: "Publication",
      iconUrl: nil,
      avatarUrl: nil,
      discoveredAt: Date(),
      appViewScope: PublicationAppViewScope(
        authorDid: authorDid,
        publicationAtUri: id,
        publicationScopeAtUris: [id],
        publicationSiteUrls: []
      )
    )
  }
}
