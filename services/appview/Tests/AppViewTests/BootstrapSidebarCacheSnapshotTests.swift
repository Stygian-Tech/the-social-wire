import AsyncHTTPClient
import Foundation
import GatewayCore
import Logging
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Sidebar podcast classification cache")
struct BootstrapSidebarCacheSnapshotTests {
  private func snapshot() -> BootstrapSidebarCacheSnapshot {
    BootstrapSidebarCacheSnapshot(priority: PublicationSidebarResponse(
      viewerDid: "did:plc:viewer", folders: [], publicationPrefs: [], folderSections: [],
      allPublicationRows: [], myPublications: [], subscribedUnfoldered: [], followingTabPublications: [],
      enrollAuthorDids: [], totalUnreadCount: 0, refreshedAt: Date()), folderPayload: nil)
  }

  @Test("new sidebar caches carry the classification version and round trip")
  func currentVersionRoundTrip() throws {
    let data = try JSONEncoder().encode(snapshot())
    let decoded = try JSONDecoder().decode(BootstrapSidebarCacheSnapshot.self, from: data)
    #expect(decoded.version == BootstrapSidebarCacheSnapshot.currentVersion)
    #expect(decoded.priority.subscribedUnfoldered.isEmpty)
    #expect(decoded.priority.totalUnreadCount == 0)
  }

  @Test("legacy and mismatched caches cannot restore stale podcast rows or unread totals")
  func legacyVersionsRejected() throws {
    let encoded = try JSONEncoder().encode(snapshot())
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json.removeValue(forKey: "version")
    let legacy = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(BootstrapSidebarCacheSnapshot.self, from: legacy) }
    json["version"] = BootstrapSidebarCacheSnapshot.currentVersion + 1
    let future = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(BootstrapSidebarCacheSnapshot.self, from: future) }
  }

  @Test("cached aggregate and sidebar readers reject old snapshots without contacting the PDS")
  func staleCacheCannotRebuildArticleMembership() async throws {
    let logger = Logger(label: "podcast-sidebar-cache.test")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try SQLiteThinAppViewStore(path: folder.appendingPathComponent("store.sqlite").path, logger: logger)
    let cache = try SQLiteAppViewProjectionCacheStore(path: folder.appendingPathComponent("cache.sqlite").path, logger: logger)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
    legacy.removeValue(forKey: "version")
    let json = String(decoding: try JSONSerialization.data(withJSONObject: legacy), as: UTF8.self)
    try await cache.storeSidebarProjectionJSON(viewerDid: "did:plc:viewer", jsonBody: json, expiresAt: Date().addingTimeInterval(300))
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    let service = PublicationProjectionService(httpClient: http, plcURL: "http://127.0.0.1:1", logger: logger, thinStore: store, projectionCache: cache)
    #expect(await service.cachedSidebarResponse(viewerDid: "did:plc:viewer") == nil)
    #expect(await service.rebuildFeedProjectionFromCachedSidebar(viewerDid: "did:plc:viewer") == false)
    try await http.shutdown()
  }
}
