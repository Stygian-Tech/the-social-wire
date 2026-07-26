import Foundation
import GatewayCore
import Logging
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Thin AppView first-page cache evidence")
struct ThinAppViewReadServiceCacheEvidenceTests {
  @Test("cached first page preserves its stored timestamps and source")
  func cachedFirstPagePreservesEvidence() async throws {
    let logger = Logger(label: "read-service-cache.test")
    let appViewPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("read-service-appview-\(UUID().uuidString).sqlite")
      .path
    let cachePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("read-service-cache-\(UUID().uuidString).sqlite")
      .path
    defer {
      try? FileManager.default.removeItem(atPath: appViewPath)
      try? FileManager.default.removeItem(atPath: cachePath)
    }

    let store = try SQLiteThinAppViewStore(path: appViewPath, logger: logger)
    let cache = try SQLiteAppViewProjectionCacheStore(path: cachePath, logger: logger)
    let service = ThinAppViewReadService(
      store: store,
      projectionCache: cache,
      logger: logger
    )
    let publicationId = "at://did:plc:alice/site.standard.publication/main"
    let page = AppViewEntryListResponse(
      entries: [
        AppViewEntryListItem(
          entryId: "at://did:plc:alice/site.standard.document/article",
          title: "Cached article",
          publishedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
      ],
      cursor: "next"
    )
    let data = try JSONEncoder().encode(page)
    let json = try #require(String(data: data, encoding: .utf8))
    let expiresAt = Date().addingTimeInterval(300)
    try await cache.storeFirstPageJSON(
      viewerDid: "did:plc:viewer",
      publicationId: publicationId,
      jsonBody: json,
      expiresAt: expiresAt
    )
    let stored = try #require(
      try await cache.firstPageCacheEntry(
        viewerDid: "did:plc:viewer",
        publicationId: publicationId
      )
    )

    let result = try #require(
      try await service.cachedFirstPageIfAvailable(
        auth: AuthContext(
          did: "did:plc:viewer",
          authorizationForwardingValue: "DPoP token",
          dpopProof: "proof"
        ),
        publicationId: publicationId,
        scope: PublicationAppViewScope(
          authorDid: "did:plc:alice",
          publicationAtUri: publicationId,
          publicationScopeAtUris: [publicationId],
          publicationSiteUrls: []
        ),
        limit: 50
      )
    )

    #expect(result.source == .projectionCache)
    #expect(result.cachedAt == stored.cachedAt)
    #expect(result.expiresAt == stored.expiresAt)
    #expect(result.value.entries.first?.title == "Cached article")
    #expect(result.value.cursor == "next")
  }
}
