import Foundation
import Logging
import SocialWireRedis
import Testing

@testable import ThinAppViewCore

@Suite("ThinAppViewIndexer")
struct ThinAppViewIndexerTests {
  private actor StubPublicationSiteResolver: PublicationSiteBaseResolving {
    private let base: String?
    private(set) var lookups: [String] = []

    init(base: String?) {
      self.base = base
    }

    func siteBase(forPublicationAtUri atUri: String) async -> String? {
      lookups.append(atUri)
      return base
    }

    func lookupCount() -> Int { lookups.count }
  }

  @Test("resolves articleUrl for documents that reference their publication by AT-URI")
  func resolvesArticleUrlFromPublicationRecord() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-indexer-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let logger = Logger(label: "indexer.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let publication = "at://did:plc:author/site.standard.publication/main"
    let resolver = StubPublicationSiteResolver(base: "https://example.com")
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      publicationSiteResolver: resolver
    )

    for (rkey, path) in [("one", "/posts/one"), ("two", "posts/two")] {
      let recordJSON = try JSONSerialization.data(withJSONObject: [
        "title": "Article \(rkey)",
        "publishedAt": "2026-05-19T12:00:00.000Z",
        "site": publication,
        "path": path,
      ])
      try await indexer.handleCommit(
        repoDid: "did:plc:author",
        collection: "site.standard.document",
        rkey: rkey,
        cid: "bafy\(rkey)",
        recordJSON: recordJSON,
        operation: "create"
      )
    }

    let first = try await store.fetchContentItem(
      uri: "at://did:plc:author/site.standard.document/one"
    )
    #expect(first?.originalUrl == "https://example.com/posts/one")
    let second = try await store.fetchContentItem(
      uri: "at://did:plc:author/site.standard.document/two"
    )
    #expect(second?.originalUrl == "https://example.com/posts/two")
    // The publication is resolved per document, but the resolver caches across them.
    #expect(await resolver.lookupCount() == 2)
    #expect(await resolver.lookups.allSatisfy { $0 == publication })
  }

  @Test("indexes documents without a resolver and leaves articleUrl empty")
  func indexesWithoutResolver() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-indexer-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let logger = Logger(label: "indexer.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let indexer = ThinAppViewIndexer(store: store, config: config, logger: logger)

    let recordJSON = try JSONSerialization.data(withJSONObject: [
      "title": "Unresolvable",
      "publishedAt": "2026-05-19T12:00:00.000Z",
      "site": "at://did:plc:author/site.standard.publication/main",
      "path": "/posts/one",
    ])
    try await indexer.handleCommit(
      repoDid: "did:plc:author",
      collection: "site.standard.document",
      rkey: "one",
      cid: "bafyone",
      recordJSON: recordJSON,
      operation: "create"
    )

    let item = try await store.fetchContentItem(
      uri: "at://did:plc:author/site.standard.document/one"
    )
    #expect(item?.title == "Unresolvable")
    #expect(item?.originalUrl == nil)
  }

  @Test("indexes document commit and clears cached first page for publication")
  func indexesDocumentAndInvalidatesFirstPage() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-indexer-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let logger = Logger(label: "indexer.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let cachePath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-indexer-cache-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: cachePath) }
    let projectionCache = try SQLiteAppViewProjectionCacheStore(path: cachePath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let publication =
      "at://did:plc:author/site.standard.publication/main"
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      projectionCache: projectionCache
    )

    try await projectionCache.storeFirstPageJSON(
      viewerDid: "did:plc:viewer",
      publicationId: publication,
      jsonBody: #"{"entries":[{"entryId":"at://did:plc:author/site.standard.document/old","title":"Old","publishedAt":"2026-05-19T12:00:00.000Z"}]}"#,
      expiresAt: Date().addingTimeInterval(3600)
    )

    let record: [String: Any] = [
      "title": "Indexed Article",
      "publishedAt": "2026-05-19T12:00:00.000Z",
      "summary": "Snippet",
      "site": publication,
    ]
    let recordJSON = try JSONSerialization.data(withJSONObject: record)

    try await indexer.handleCommit(
      repoDid: "did:plc:author",
      collection: "site.standard.document",
      rkey: "abc",
      cid: "bafyindex",
      recordJSON: recordJSON,
      operation: "create"
    )

    #expect(
      try await projectionCache.cachedFirstPageJSON(
        viewerDid: "did:plc:viewer",
        publicationId: publication
      ) == nil
    )
  }

  @Test("indexes document commit into content_items")
  func indexesDocument() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-indexer-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let logger = Logger(label: "indexer.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let indexer = ThinAppViewIndexer(store: store, config: config, logger: logger)

    let record: [String: Any] = [
      "title": "Indexed Article",
      "publishedAt": "2026-05-19T12:00:00.000Z",
      "summary": "Snippet",
    ]
    let recordJSON = try JSONSerialization.data(withJSONObject: record)

    try await indexer.handleCommit(
      repoDid: "did:plc:author",
      collection: "site.standard.document",
      rkey: "abc",
      cid: "bafyindex",
      recordJSON: recordJSON,
      operation: "create"
    )

    let all = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: "did:plc:author",
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .all,
      cursor: nil,
      limit: 10
    )
    #expect(all.entries.count == 1)
    #expect(all.entries.first?.title == "Indexed Article")
  }

  @Test("indexes document when the disposable projection cache is unavailable")
  func indexesDocumentWhenProjectionCacheIsUnavailable() async throws {
    let dbPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-indexer-cache-outage-\(UUID().uuidString).sqlite")
      .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let logger = Logger(label: "indexer.cache-outage.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let projectionCache = RedisAppViewProjectionCacheStore(
      commands: UnavailableIndexerRedisCommands(),
      environment: "test",
      logger: logger
    )
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      projectionCache: projectionCache
    )
    let recordJSON = try JSONSerialization.data(withJSONObject: [
      "title": "Durably Indexed",
      "publishedAt": "2026-08-12T21:41:07.000Z",
      "site": "at://did:plc:author/site.standard.publication/main",
    ])

    try await indexer.handleCommit(
      repoDid: "did:plc:author",
      collection: "site.standard.document",
      rkey: "cache-outage",
      cid: "bafycacheoutage",
      recordJSON: recordJSON,
      operation: "create"
    )

    let indexed = try await store.fetchContentItem(
      uri: "at://did:plc:author/site.standard.document/cache-outage"
    )
    #expect(indexed?.title == "Durably Indexed")
  }

  @Test("delete operation removes content item")
  func deletesContent() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-del-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let logger = Logger(label: "indexer.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let indexer = ThinAppViewIndexer(store: store, config: config, logger: logger)

    let uri = "at://did:plc:author/site.standard.document/abc"
    let now = Date()
    try await store.upsertContentItem(
      IndexedContentItem(
        uri: uri,
        cid: "bafy",
        authorDid: "did:plc:author",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: nil,
        render: ContentRenderFields(title: "Gone", publishedAt: ISO8601DateFormatter().string(from: now)),
        expiresAt: now.addingTimeInterval(3600)
      )
    )

    try await indexer.handleCommit(
      repoDid: "did:plc:author",
      collection: "site.standard.document",
      rkey: "abc",
      cid: "bafy",
      recordJSON: Data("{}".utf8),
      operation: "delete"
    )

    let all = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: "did:plc:author",
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .all,
      cursor: nil,
      limit: 10
    )
    #expect(all.entries.isEmpty)
  }

  @Test("graph subscription commit invalidates viewer sidebar projection cache")
  func graphSubscriptionInvalidatesSidebarCache() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-graph-sub-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let cachePath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-graph-sub-cache-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: cachePath) }

    let logger = Logger(label: "indexer.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let projectionCache = try SQLiteAppViewProjectionCacheStore(path: cachePath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      projectionCache: projectionCache
    )

    try await projectionCache.storeSidebarProjectionJSON(
      viewerDid: "did:plc:viewer",
      jsonBody: #"{"viewerDid":"did:plc:viewer"}"#,
      expiresAt: Date().addingTimeInterval(3600)
    )

    let record: [String: Any] = [
      "publication": "at://did:plc:author/site.standard.publication/main",
    ]
    let recordJSON = try JSONSerialization.data(withJSONObject: record)

    try await indexer.handleCommit(
      repoDid: "did:plc:viewer",
      collection: ThinAppViewConfig.graphSubscriptionCollection,
      rkey: "sub1",
      cid: "bafysub",
      recordJSON: recordJSON,
      operation: "create"
    )

    #expect(try await projectionCache.cachedSidebarProjectionJSON(viewerDid: "did:plc:viewer") == nil)
  }

  @Test("skyreader subscription commit warms first page when feed rows already indexed")
  func skyreaderSubscriptionWarmsFirstPage() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-rss-sub-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let cachePath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-rss-sub-cache-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: cachePath) }

    let logger = Logger(label: "indexer.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let projectionCache = try SQLiteAppViewProjectionCacheStore(path: cachePath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      projectionCache: projectionCache
    )

    let feedUrl = "https://example.com/feed.xml"
    let publicationId = RssFeedIdentity.rssPublicationId(from: feedUrl)
    let now = Date()
    let entryUri = RssFeedIdentity.rssEntryId(normalizedFeedUrl: feedUrl, stableItemKey: "link:\(feedUrl)/one")
    try await store.upsertContentItem(
      IndexedContentItem(
        uri: entryUri,
        cid: RssFeedIdentity.deterministicCid(for: entryUri),
        authorDid: RssFeedLexicons.rssAuthorDid,
        collection: RssFeedLexicons.skyreaderFeedEntry,
        createdAt: now,
        indexedAt: now,
        publicationSite: feedUrl,
        render: ContentRenderFields(
          title: "RSS Item",
          publishedAt: ISO8601DateFormatter().string(from: now)
        ),
        expiresAt: now.addingTimeInterval(3600)
      )
    )

    let record: [String: Any] = [
      "feedUrl": feedUrl,
      "sourceType": "rss",
    ]
    let recordJSON = try JSONSerialization.data(withJSONObject: record)

    try await indexer.handleCommit(
      repoDid: "did:plc:viewer",
      collection: RssFeedLexicons.skyreaderFeedSubscription,
      rkey: "rss1",
      cid: "bafyrss",
      recordJSON: recordJSON,
      operation: "create"
    )

    let cached = try await projectionCache.cachedFirstPageJSON(
      viewerDid: AppViewProjectionCacheViewerKeys.sharedFirstPage,
      publicationId: publicationId
    )
    #expect(cached?.contains("RSS Item") == true)
  }
}

private actor UnavailableIndexerRedisCommands: RedisCommandClient {
  struct Unavailable: Error {}

  func get(_ key: String) throws -> Data? { throw Unavailable() }
  func set(_ key: String, value: Data, expirationMilliseconds: Int) throws { throw Unavailable() }
  func setIfAbsent(_ key: String, value: Data, expirationMilliseconds: Int) throws -> Bool {
    throw Unavailable()
  }
  func delete(_ keys: [String]) throws -> Int { throw Unavailable() }
  func execute(command: String, arguments: [RedisCommandValue]) throws -> RedisCommandValue {
    throw Unavailable()
  }
  func ping() throws { throw Unavailable() }
  func shutdown() {}
}

@Suite("ThinAppViewQuerySupport")
struct ThinAppViewQuerySupportTests {
  @Test("ThinAppViewCursor round-trips createdAt and uri")
  func cursorRoundTrip() {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: "2026-05-19T12:00:00.000Z")!
    let uri = "at://did:plc:author/site.standard.document/abc"
    let encoded = ThinAppViewCursor.encode(createdAt: date, uri: uri)
    let decoded = ThinAppViewCursor.decode(encoded)
    #expect(decoded?.uri == uri)
  }

  @Test("entryListItems decodes render JSON rows")
  func entryListItems() {
    let iso = ISO8601DateFormatter().string(from: Date())
    let renderJSON = #"{"title":"Hello","publishedAt":"\#(iso)"}"#
    let items = ThinAppViewQuerySupport.entryListItems(
      from: [(uri: "at://did:plc:a/site.standard.document/x", renderJSON: renderJSON, createdAt: Date())]
    )
    #expect(items.count == 1)
    #expect(items[0].title == "Hello")
    #expect(items[0].entryId.contains("/x"))
    #expect(items[0].originalUrl == nil)
  }

  @Test("entryListItems includes originalUrl from render articleUrl")
  func entryListItemsOriginalUrl() {
    let iso = ISO8601DateFormatter().string(from: Date())
    let renderJSON =
      #"{"title":"Story","publishedAt":"\#(iso)","articleUrl":"https://example.com/posts/story"}"#
    let items = ThinAppViewQuerySupport.entryListItems(
      from: [(uri: "at://did:plc:a/site.standard.document/x", renderJSON: renderJSON, createdAt: Date())]
    )
    #expect(items.count == 1)
    #expect(items[0].originalUrl == "https://example.com/posts/story")
  }
}
