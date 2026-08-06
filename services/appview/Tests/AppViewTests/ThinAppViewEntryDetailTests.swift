import Foundation
import GatewayCore
import Logging
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Thin AppView entry detail")
struct ThinAppViewEntryDetailTests {
  private func makeService(
    logger: Logger,
    appViewPath: String,
    cachePath: String
  ) throws -> (ThinAppViewReadService, SQLiteThinAppViewStore) {
    let store = try SQLiteThinAppViewStore(path: appViewPath, logger: logger)
    let cache = try SQLiteAppViewProjectionCacheStore(path: cachePath, logger: logger)
    return (
      ThinAppViewReadService(store: store, projectionCache: cache, logger: logger),
      store
    )
  }

  private func indexDocument(
    into store: SQLiteThinAppViewStore,
    entryId: String,
    articleUrl: String?
  ) async throws {
    let now = Date()
    try await store.upsertContentItem(
      IndexedContentItem(
        uri: entryId,
        cid: "bafyarticle",
        authorDid: "did:plc:alice",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: "at://did:plc:alice/site.standard.publication/main",
        render: ContentRenderFields(
          title: "Standard site article",
          publishedAt: ISO8601DateFormatter().string(from: now),
          articleUrl: articleUrl
        ),
        expiresAt: now.addingTimeInterval(3600)
      )
    )
  }

  @Test("entry detail serves the indexed hosted article URL")
  func entryDetailReturnsOriginalUrl() async throws {
    let logger = Logger(label: "entry-detail.test")
    let appViewPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("entry-detail-appview-\(UUID().uuidString).sqlite")
      .path
    let cachePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("entry-detail-cache-\(UUID().uuidString).sqlite")
      .path
    defer {
      try? FileManager.default.removeItem(atPath: appViewPath)
      try? FileManager.default.removeItem(atPath: cachePath)
    }

    let (service, store) = try makeService(
      logger: logger,
      appViewPath: appViewPath,
      cachePath: cachePath
    )
    let entryId = "at://did:plc:alice/site.standard.document/article"
    try await indexDocument(
      into: store,
      entryId: entryId,
      articleUrl: "https://example.com/posts/hello"
    )

    let detail = try await service.entryDetail(
      auth: AuthContext(
        did: "did:plc:viewer",
        authorizationForwardingValue: "DPoP token",
        dpopProof: "proof"
      ),
      entryId: entryId
    )

    #expect(detail.entryId == entryId)
    #expect(detail.originalUrl == "https://example.com/posts/hello")
  }

  @Test("entry list rows carry the hosted article URL")
  func entryListCarriesOriginalUrl() async throws {
    let logger = Logger(label: "entry-detail.test")
    let appViewPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("entry-list-appview-\(UUID().uuidString).sqlite")
      .path
    let cachePath = FileManager.default.temporaryDirectory
      .appendingPathComponent("entry-list-cache-\(UUID().uuidString).sqlite")
      .path
    defer {
      try? FileManager.default.removeItem(atPath: appViewPath)
      try? FileManager.default.removeItem(atPath: cachePath)
    }

    let (_, store) = try makeService(
      logger: logger,
      appViewPath: appViewPath,
      cachePath: cachePath
    )
    let entryId = "at://did:plc:alice/site.standard.document/article"
    try await indexDocument(
      into: store,
      entryId: entryId,
      articleUrl: "https://example.com/posts/hello"
    )

    let page = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: "did:plc:alice",
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .all,
      cursor: nil,
      limit: 10
    )

    #expect(page.entries.first?.originalUrl == "https://example.com/posts/hello")
  }
}
