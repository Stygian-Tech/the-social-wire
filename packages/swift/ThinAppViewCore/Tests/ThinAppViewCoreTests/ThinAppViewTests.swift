import Foundation
import Logging
import Testing
import ThinAppViewCore

@Suite("RenderFieldExtractor")
struct RenderFieldExtractorTests {
  @Test("extracts title and publishedAt from document record")
  func extractDocumentFields() {
    let fields = RenderFieldExtractor.extractRenderFields(from: [
      "title": "Hello",
      "publishedAt": "2026-05-19T12:00:00.000Z",
      "summary": "Snippet",
    ])
    #expect(fields.title == "Hello")
    #expect(fields.publishedAt == "2026-05-19T12:00:00.000Z")
    #expect(fields.summary == "Snippet")
  }

  @Test("extracts articleUrl from direct standard.site URL fields")
  func extractDirectArticleUrl() {
    let fields = RenderFieldExtractor.extractRenderFields(from: [
      "title": "Hello",
      "publishedAt": "2026-05-19T12:00:00.000Z",
      "url": "http://example.com/posts/hello#comments",
    ])
    #expect(fields.articleUrl == "https://example.com/posts/hello")
  }

  @Test("builds articleUrl from HTTPS site and path")
  func extractArticleUrlFromSitePath() {
    let fields = RenderFieldExtractor.extractRenderFields(from: [
      "title": "Hello",
      "publishedAt": "2026-05-19T12:00:00.000Z",
      "site": "https://example.com/",
      "path": "/posts/hello",
    ])
    #expect(fields.articleUrl == "https://example.com/posts/hello")
  }

  @Test("matches publication site equivalence keys")
  func publicationEquivalence() {
    let pub = "at://did:plc:abc/site.standard.publication/main"
    let keys = RenderFieldExtractor.publicationFilterEquivalenceKeys(publicationAtUri: pub)
    #expect(keys.contains("at://did:plc:abc/site.standard.publication/main"))
    #expect(keys.contains("at://did:plc:abc/com.standard.publication/main"))
    #expect(
      RenderFieldExtractor.matchesPublication(
        siteField: "at://did:plc:abc/com.standard.publication/main",
        publicationAtUri: pub
      )
    )
  }

  @Test("reads publicationUri from document records")
  func publicationUriField() {
    let pub = "at://did:plc:abc/site.standard.publication/offprint"
    let record: [String: Any] = [
      "publicationUri": pub,
      "title": "Post",
    ]
    #expect(RenderFieldExtractor.publicationSiteField(from: record) == pub)
    #expect(
      RenderFieldExtractor.matchesPublication(
        siteField: RenderFieldExtractor.publicationSiteField(from: record),
        publicationAtUri: pub
      )
    )
  }

  @Test("matches publication https url on document site field")
  func publicationHttpsUrl() {
    let pub = "at://did:plc:abc/site.standard.publication/main"
    #expect(
      RenderFieldExtractor.matchesPublication(
        siteField: "https://news.offprint.app",
        publicationAtUri: pub,
        publicationSiteUrls: ["https://news.offprint.app"]
      )
    )
  }
}

@Suite("AppViewReadMarkRequest")
struct AppViewReadMarkRequestTests {
  @Test("decodes ISO8601 readAt strings from the web client")
  func decodesReadAtString() throws {
    let json = """
      {"subjectUri":"at://did:plc:author/site.standard.document/one","readAt":"2026-05-20T12:34:56.789Z"}
      """
    let decoded = try JSONDecoder().decode(AppViewReadMarkRequest.self, from: Data(json.utf8))
    #expect(decoded.subjectUri == "at://did:plc:author/site.standard.document/one")
    #expect(decoded.readAt != nil)
  }
}

@Suite("SQLiteThinAppViewStore")
struct SQLiteThinAppViewStoreTests {
  @Test("indexes content and filters unread entries")
  func unreadFilter() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let render = ContentRenderFields(title: "One", publishedAt: ISO8601DateFormatter().string(from: now))
    try await store.upsertContentItem(
      IndexedContentItem(
        uri: "at://did:plc:author/site.standard.document/one",
        cid: "bafyone",
        authorDid: "did:plc:author",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: nil,
        render: render,
        expiresAt: now.addingTimeInterval(3600)
      )
    )
    try await store.upsertContentItem(
      IndexedContentItem(
        uri: "at://did:plc:author/site.standard.document/two",
        cid: "bafytwo",
        authorDid: "did:plc:author",
        collection: "site.standard.document",
        createdAt: now.addingTimeInterval(-60),
        indexedAt: now,
        publicationSite: nil,
        render: ContentRenderFields(title: "Two", publishedAt: ISO8601DateFormatter().string(from: now)),
        expiresAt: now.addingTimeInterval(3600)
      )
    )
    try await store.upsertReadMark(
      viewerDid: "did:plc:viewer",
      subjectUri: "at://did:plc:author/site.standard.document/one",
      createdAt: now
    )

    let unread = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: "did:plc:author",
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: EntryListFilter.unread,
      cursor: nil,
      limit: 10
    )
    #expect(unread.entries.count == 1)
    #expect(unread.entries.first?.entryId.contains("/two") == true)

    let unreadCount = try await store.countUnreadEntries(
      viewerDid: "did:plc:viewer",
      authorDid: "did:plc:author",
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: []
    )
    #expect(unreadCount == 1)

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
    #expect(all.entries.count == 2)
  }

  @Test("unread listing excludes entries at or below mark-all-read floor")
  func unreadFilterRespectsReadFloor() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let floor = ISO8601DateFormatter().date(from: "2026-05-20T12:00:00.000Z") ?? Date()
    let publicationId = "at://did:plc:author/site.standard.publication/main"
    let olderUri = "at://did:plc:author/site.standard.document/older"
    let newerUri = "at://did:plc:author/site.standard.document/newer"

    for (uri, createdAt, title) in [
      (olderUri, floor.addingTimeInterval(-60), "Older"),
      (newerUri, floor.addingTimeInterval(60), "Newer"),
    ] {
      try await store.upsertContentItem(
        IndexedContentItem(
          uri: uri,
          cid: "bafy-\(title)",
          authorDid: "did:plc:author",
          collection: "site.standard.document",
          createdAt: createdAt,
          indexedAt: floor,
          publicationSite: publicationId,
          render: ContentRenderFields(title: title, publishedAt: ISO8601DateFormatter().string(from: createdAt)),
          expiresAt: floor.addingTimeInterval(3600)
        )
      )
    }

    _ = try await store.markAllReadCounters(
      viewerDid: "did:plc:viewer",
      scopes: [
        PublicationUnreadScope(
          publicationId: publicationId,
          authorDid: "did:plc:author",
          publicationAtUri: publicationId,
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        )
      ],
      readAt: floor
    )
    let readBoundary = try await store.readBoundary(
      viewerDid: "did:plc:viewer",
      publicationId: publicationId
    )

    let unread = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: "did:plc:author",
      publicationAtUri: publicationId,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .unread,
      cursor: nil,
      limit: 10,
      readBoundary: readBoundary
    )

    #expect(unread.entries.map(\.entryId) == [newerUri])
  }

  @Test("batch unread counts aggregate by author and publication scope")
  func batchUnreadCountsAggregateScopes() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let pubA = "at://did:plc:author/site.standard.publication/a"
    let pubB = "at://did:plc:author/site.standard.publication/b"
    let feedA = "https://a.example.com/feed.xml"
    let feedB = "https://b.example.com/feed.xml"

    for (index, site) in [pubA, pubA, pubB].enumerated() {
      let uri = "at://did:plc:author/site.standard.document/\(index)"
      try await store.upsertContentItem(
        IndexedContentItem(
          uri: uri,
          cid: "bafy\(index)",
          authorDid: "did:plc:author",
          collection: "site.standard.document",
          createdAt: now.addingTimeInterval(TimeInterval(-index)),
          indexedAt: now,
          publicationSite: site,
          render: ContentRenderFields(title: "Standard \(index)", publishedAt: ISO8601DateFormatter().string(from: now)),
          expiresAt: now.addingTimeInterval(3600)
        )
      )
      if index == 0 {
        try await store.upsertReadMark(
          viewerDid: "did:plc:viewer",
          subjectUri: uri,
          createdAt: now
        )
      }
    }

    for (feed, title) in [(feedA, "Feed A"), (feedB, "Feed B")] {
      let uri = RssFeedIdentity.rssEntryId(normalizedFeedUrl: feed, stableItemKey: "guid:\(title)")
      try await store.upsertContentItem(
        IndexedContentItem(
          uri: uri,
          cid: "rss:\(title)",
          authorDid: RssFeedLexicons.rssAuthorDid,
          collection: RssFeedLexicons.skyreaderFeedEntry,
          createdAt: now,
          indexedAt: now,
          publicationSite: feed,
          render: ContentRenderFields(title: title, publishedAt: ISO8601DateFormatter().string(from: now)),
          expiresAt: now.addingTimeInterval(3600)
        )
      )
      if feed == feedB {
        try await store.upsertReadMark(
          viewerDid: "did:plc:viewer",
          subjectUri: uri,
          createdAt: now
        )
      }
    }

    let counts = try await store.countUnreadEntriesBatch(
      viewerDid: "did:plc:viewer",
      scopes: [
        PublicationUnreadScope(
          publicationId: "author-all",
          authorDid: "did:plc:author",
          publicationAtUri: nil,
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        ),
        PublicationUnreadScope(
          publicationId: "pub-a",
          authorDid: "did:plc:author",
          publicationAtUri: pubA,
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        ),
        PublicationUnreadScope(
          publicationId: "pub-b",
          authorDid: "did:plc:author",
          publicationAtUri: pubB,
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        ),
        PublicationUnreadScope(
          publicationId: "pub-empty",
          authorDid: "did:plc:author",
          publicationAtUri: "at://did:plc:author/site.standard.publication/empty",
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        ),
        PublicationUnreadScope(
          publicationId: "rss-a",
          authorDid: RssFeedLexicons.rssAuthorDid,
          publicationAtUri: nil,
          publicationScopeAtUris: [],
          publicationSiteUrls: [feedA]
        ),
        PublicationUnreadScope(
          publicationId: "rss-b",
          authorDid: RssFeedLexicons.rssAuthorDid,
          publicationAtUri: nil,
          publicationScopeAtUris: [],
          publicationSiteUrls: [feedB]
        ),
      ]
    )

    #expect(counts["author-all"] == 2)
    #expect(counts["pub-a"] == 1)
    #expect(counts["pub-b"] == 1)
    #expect(counts["pub-empty"] == 0)
    #expect(counts["rss-a"] == 1)
    #expect(counts["rss-b"] == 0)
  }

  @Test("materialized unread counters update from ingest read state and read floors")
  func materializedUnreadCountersLifecycle() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let viewerDid = "did:plc:viewer"
    let authorDid = "did:plc:author"
    let publicationId = "at://did:plc:author/site.standard.publication/main"
    let entryId = "at://did:plc:author/site.standard.document/one"
    let scope = AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewerDid,
      publicationId: publicationId,
      authorDid: authorDid,
      publicationAtUri: publicationId,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      sectionKeys: ["folder:main"],
      updatedAt: now
    )
    try await store.upsertPublicationScopes([scope])

    let item = IndexedContentItem(
      uri: entryId,
      cid: "bafyone",
      authorDid: authorDid,
      collection: "site.standard.document",
      createdAt: now,
      indexedAt: now,
      publicationSite: publicationId,
      render: ContentRenderFields(title: "One", publishedAt: ISO8601DateFormatter().string(from: now)),
      expiresAt: now.addingTimeInterval(3600)
    )
    try await store.upsertContentItem(item)
    try await store.incrementUnreadCountersForContentItem(item)

    #expect(try await store.fetchUnreadCounters(viewerDid: viewerDid, publicationIds: [publicationId]).first?.unreadCount == 1)

    try await store.upsertReadMark(viewerDid: viewerDid, subjectUri: entryId, createdAt: now)
    try await store.adjustUnreadCountersForReadState(viewerDid: viewerDid, subjectUri: entryId, delta: -1)
    #expect(try await store.fetchUnreadCounters(viewerDid: viewerDid, publicationIds: [publicationId]).first?.unreadCount == 0)

    try await store.deleteReadMark(viewerDid: viewerDid, subjectUri: entryId)
    try await store.adjustUnreadCountersForReadState(viewerDid: viewerDid, subjectUri: entryId, delta: 1)
    #expect(try await store.fetchUnreadCounters(viewerDid: viewerDid, publicationIds: [publicationId]).first?.unreadCount == 1)

    _ = try await store.markAllReadCounters(
      viewerDid: viewerDid,
      scopes: [
        PublicationUnreadScope(
          publicationId: publicationId,
          authorDid: authorDid,
          publicationAtUri: publicationId,
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        )
      ],
      readAt: now.addingTimeInterval(60)
    )
    #expect(try await store.fetchUnreadCounters(viewerDid: viewerDid, publicationIds: [publicationId]).first?.unreadCount == 0)

    let oldBackfill = IndexedContentItem(
      uri: "at://did:plc:author/site.standard.document/old",
      cid: "bafyold",
      authorDid: authorDid,
      collection: "site.standard.document",
      createdAt: now.addingTimeInterval(-60),
      indexedAt: now,
      publicationSite: publicationId,
      render: ContentRenderFields(title: "Old", publishedAt: ISO8601DateFormatter().string(from: now)),
      expiresAt: now.addingTimeInterval(3600)
    )
    try await store.upsertContentItem(oldBackfill)
    try await store.incrementUnreadCountersForContentItem(oldBackfill)
    #expect(try await store.fetchUnreadCounters(viewerDid: viewerDid, publicationIds: [publicationId]).first?.unreadCount == 0)

    let reconciled = try await store.refreshUnreadCounters(
      viewerDid: viewerDid,
      scopes: [
        PublicationUnreadScope(
          publicationId: publicationId,
          authorDid: authorDid,
          publicationAtUri: publicationId,
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        ),
      ]
    )
    #expect(reconciled.first?.unreadCount == 0)
    #expect(reconciled.first?.accuracy == .exact)
  }

  @Test("materialized feed selectors distinguish empty unknown and publication feeds")
  func materializedFeedSelectors() async throws {
    let dbPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let viewerDid = "did:plc:viewer"
    let publicationId = "at://did:plc:author/site.standard.publication/main"
    let scope = AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewerDid,
      publicationId: publicationId,
      authorDid: "did:plc:author",
      publicationAtUri: publicationId,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      sectionKeys: ["subscribed:unfoldered"],
      updatedAt: now
    )
    try await store.replaceViewerFeedProjection(
      viewerDid: viewerDid,
      scopes: [scope],
      feeds: [
        AppViewViewerFeed(viewerDid: viewerDid, kind: .subscribed, feedId: "", updatedAt: now),
        AppViewViewerFeed(viewerDid: viewerDid, kind: .following, feedId: "", updatedAt: now),
        AppViewViewerFeed(viewerDid: viewerDid, kind: .folder, feedId: "empty", updatedAt: now),
      ],
      memberships: [
        AppViewFeedPublication(
          viewerDid: viewerDid,
          kind: .subscribed,
          feedId: "",
          publicationId: publicationId
        ),
      ]
    )
    let entryId = "at://did:plc:author/site.standard.document/one"
    try await store.upsertContentItem(IndexedContentItem(
      uri: entryId,
      cid: "bafyone",
      authorDid: "did:plc:author",
      collection: "site.standard.document",
      createdAt: now,
      indexedAt: now,
      publicationSite: publicationId,
      render: ContentRenderFields(
        title: "One",
        publishedAt: ISO8601DateFormatter().string(from: now)
      ),
      expiresAt: now.addingTimeInterval(3_600)
    ))
    try await store.upsertReadMark(viewerDid: viewerDid, subjectUri: entryId, createdAt: now)

    let subscribed = try await store.listFeedEntries(
      viewerDid: viewerDid,
      selector: AppViewFeedSelector(kind: .subscribed),
      filter: .all,
      cursor: nil,
      limit: 50
    )
    #expect(subscribed?.response.entries.map(\.entryId) == [entryId])
    #expect(subscribed?.response.entries.first?.isRead == true)

    let publication = try await store.listFeedEntries(
      viewerDid: viewerDid,
      selector: AppViewFeedSelector(kind: .publication, id: publicationId),
      filter: .all,
      cursor: nil,
      limit: 50
    )
    #expect(publication?.response.entries.map(\.entryId) == [entryId])

    let empty = try await store.listFeedEntries(
      viewerDid: viewerDid,
      selector: AppViewFeedSelector(kind: .folder, id: "at://did:plc:viewer/app.thesocialwire.folder/empty"),
      filter: .all,
      cursor: nil,
      limit: 50
    )
    #expect(empty?.response.entries.isEmpty == true)

    let unknown = try await store.listFeedEntries(
      viewerDid: viewerDid,
      selector: AppViewFeedSelector(kind: .folder, id: "missing"),
      filter: .all,
      cursor: nil,
      limit: 50
    )
    #expect(unknown == nil)
  }

  @Test("indexer content upsert increments materialized counters once")
  func indexerContentUpsertIncrementsCountersOnce() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let viewerDid = "did:plc:viewer"
    let authorDid = "did:plc:author"
    let publicationId = "at://did:plc:author/site.standard.publication/main"
    try await store.upsertPublicationScopes([
      AppViewUnreadCounterSupport.publicationScope(
        viewerDid: viewerDid,
        publicationId: publicationId,
        authorDid: authorDid,
        publicationAtUri: publicationId,
        publicationScopeAtUris: [],
        publicationSiteUrls: [],
        sectionKeys: ["folder:main"],
        updatedAt: now
      ),
    ])

    let indexer = ThinAppViewIndexer(
      store: store,
      config: ThinAppViewConfig.fromEnvironment([:]),
      logger: Logger(label: "indexer.test")
    )
    let record = try JSONSerialization.data(withJSONObject: [
      "title": "One",
      "publishedAt": ISO8601DateFormatter().string(from: now),
      "site": publicationId,
    ])

    try await indexer.handleCommit(
      repoDid: authorDid,
      collection: "site.standard.document",
      rkey: "one",
      cid: "bafyone",
      recordJSON: record,
      operation: "create"
    )
    try await indexer.handleCommit(
      repoDid: authorDid,
      collection: "site.standard.document",
      rkey: "one",
      cid: "bafyone-updated",
      recordJSON: record,
      operation: "update"
    )

    let counter = try await store.fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationId]
    ).first
    #expect(counter?.unreadCount == 1)
    #expect(counter?.dirty == true)
  }

  @Test("fetches a single indexed entry by URI")
  func fetchContentItemByUri() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let entryId = "at://did:plc:author/site.standard.document/one"
    try await store.upsertContentItem(
      IndexedContentItem(
        uri: entryId,
        cid: "bafyone",
        authorDid: "did:plc:author",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: nil,
        render: ContentRenderFields(title: "One", publishedAt: ISO8601DateFormatter().string(from: now)),
        expiresAt: now.addingTimeInterval(3600)
      )
    )

    let item = try await store.fetchContentItem(uri: entryId)
    #expect(item?.entryId == entryId)
    #expect(item?.title == "One")
    #expect(try await store.hasReadMark(viewerDid: "did:plc:viewer", subjectUri: entryId) == false)
  }

  @Test("scoped listing scans past unrelated publication rows")
  func scopedScanFindsPublicationMatches() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let targetPublication = "at://did:plc:author/site.standard.publication/main"
    let otherPublication = "at://did:plc:author/site.standard.publication/other"

    for index in 0..<130 {
      let createdAt = now.addingTimeInterval(TimeInterval(-index))
      try await store.upsertContentItem(
        IndexedContentItem(
          uri: "at://did:plc:author/site.standard.document/noise-\(index)",
          cid: "bafynoise\(index)",
          authorDid: "did:plc:author",
          collection: "site.standard.document",
          createdAt: createdAt,
          indexedAt: now,
          publicationSite: otherPublication,
          render: ContentRenderFields(
            title: "Noise \(index)",
            publishedAt: ISO8601DateFormatter().string(from: createdAt)
          ),
          expiresAt: now.addingTimeInterval(3600)
        )
      )
    }

    for index in 0..<12 {
      let createdAt = now.addingTimeInterval(TimeInterval(-200 - index))
      try await store.upsertContentItem(
        IndexedContentItem(
          uri: "at://did:plc:author/site.standard.document/match-\(index)",
          cid: "bafymatch\(index)",
          authorDid: "did:plc:author",
          collection: "site.standard.document",
          createdAt: createdAt,
          indexedAt: now,
          publicationSite: targetPublication,
          render: ContentRenderFields(
            title: "Match \(index)",
            publishedAt: ISO8601DateFormatter().string(from: createdAt)
          ),
          expiresAt: now.addingTimeInterval(3600)
        )
      )
    }

    let page = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: "did:plc:author",
      publicationAtUri: targetPublication,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .all,
      cursor: nil,
      limit: 50
    )

    #expect(page.entries.count == 12)
    #expect(page.entries.allSatisfy { $0.title.hasPrefix("Match") })
  }

  @Test("RSS publication scope filters by feed URL site field")
  func rssPublicationSiteScope() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let feedA = "https://a.example.com/feed.xml"
    let feedB = "https://b.example.com/feed.xml"

    for (feed, title) in [(feedA, "A"), (feedB, "B")] {
      try await store.upsertContentItem(
        IndexedContentItem(
          uri: RssFeedIdentity.rssEntryId(normalizedFeedUrl: feed, stableItemKey: "guid:\(title)"),
          cid: "rss:\(title)",
          authorDid: RssFeedLexicons.rssAuthorDid,
          collection: RssFeedLexicons.skyreaderFeedEntry,
          createdAt: now,
          indexedAt: now,
          publicationSite: feed,
          render: ContentRenderFields(title: title, publishedAt: ISO8601DateFormatter().string(from: now)),
          expiresAt: now.addingTimeInterval(3600)
        )
      )
    }

    let page = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: RssFeedLexicons.rssAuthorDid,
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [feedA],
      filter: .all,
      cursor: nil,
      limit: 50
    )

    #expect(page.entries.count == 1)
    #expect(page.entries[0].title == "A")
  }

  @Test("RSS publication scope preserves query-specific feed URL")
  func rssPublicationSiteScopeWithQuery() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let now = Date()
    let rssFeed = "https://basicappleguy.com/basicappleblog?format=rss"
    let atomFeed = "https://basicappleguy.com/basicappleblog?format=atom"

    for (feed, title) in [(rssFeed, "RSS"), (atomFeed, "Atom")] {
      try await store.upsertContentItem(
        IndexedContentItem(
          uri: RssFeedIdentity.rssEntryId(normalizedFeedUrl: feed, stableItemKey: "guid:\(title)"),
          cid: "rss:\(title)",
          authorDid: RssFeedLexicons.rssAuthorDid,
          collection: RssFeedLexicons.skyreaderFeedEntry,
          createdAt: now,
          indexedAt: now,
          publicationSite: feed,
          render: ContentRenderFields(title: title, publishedAt: ISO8601DateFormatter().string(from: now)),
          expiresAt: now.addingTimeInterval(3600)
        )
      )
    }

    let page = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: RssFeedLexicons.rssAuthorDid,
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [rssFeed],
      filter: .all,
      cursor: nil,
      limit: 50
    )

    #expect(page.entries.map(\.title) == ["RSS"])
  }

  @Test("watermark tuple covers late rows and explicit unread until a newer bulk action")
  func watermarkTupleAndUnreadOverride() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-appview-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let store = try SQLiteThinAppViewStore(path: dbPath, logger: Logger(label: "appview.test"))
    let viewerDid = "did:plc:viewer"
    let authorDid = "did:plc:author"
    let publicationId = "at://did:plc:author/site.standard.publication/main"
    let timestamp = ISO8601DateFormatter().date(from: "2027-07-28T20:00:00Z") ?? Date()
    let scope = PublicationUnreadScope(
      publicationId: publicationId,
      authorDid: authorDid,
      publicationAtUri: publicationId,
      publicationScopeAtUris: [],
      publicationSiteUrls: []
    )

    func item(_ suffix: String, at createdAt: Date = timestamp) -> IndexedContentItem {
      let uri = "at://did:plc:author/site.standard.document/\(suffix)"
      return IndexedContentItem(
        uri: uri,
        cid: "bafy-\(suffix)",
        authorDid: authorDid,
        collection: "site.standard.document",
        createdAt: createdAt,
        indexedAt: timestamp,
        publicationSite: publicationId,
        render: ContentRenderFields(
          title: suffix,
          publishedAt: ISO8601DateFormatter().string(from: createdAt)
        ),
        expiresAt: timestamp.addingTimeInterval(3600)
      )
    }

    try await store.upsertContentItem(item("a"))
    try await store.upsertContentItem(item("b"))
    _ = try await store.markAllReadCounters(
      viewerDid: viewerDid,
      scopes: [scope],
      readAt: timestamp.addingTimeInterval(1)
    )

    try await store.upsertContentItem(item("older", at: timestamp.addingTimeInterval(-60)))
    try await store.upsertContentItem(item("c"))
    let all = try await store.listEntries(
      viewerDid: viewerDid,
      authorDid: authorDid,
      publicationAtUri: publicationId,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .all,
      cursor: nil,
      limit: 10,
      readBoundary: nil
    )
    let states = try await store.readStates(
      viewerDid: viewerDid,
      entries: all.entries.map { $0.withPublicationId(publicationId) }
    )
    #expect(states["at://did:plc:author/site.standard.document/a"] == true)
    #expect(states["at://did:plc:author/site.standard.document/b"] == true)
    #expect(states["at://did:plc:author/site.standard.document/older"] == true)
    #expect(states["at://did:plc:author/site.standard.document/c"] == false)

    let b = "at://did:plc:author/site.standard.document/b"
    try await store.markEntryUnread(viewerDid: viewerDid, subjectUri: b, createdAt: timestamp)
    let bItem = all.entries.first { $0.entryId == b }!.withPublicationId(publicationId)
    _ = try await store.refreshUnreadCounters(viewerDid: viewerDid, scopes: [scope])
    #expect(try await store.readStates(viewerDid: viewerDid, entries: [bItem])[b] == false)
    let unreadOverrideCounters = try await store.fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationId]
    )
    #expect(unreadOverrideCounters.first?.unreadCount == 2)

    _ = try await store.markAllReadCounters(
      viewerDid: viewerDid,
      scopes: [scope],
      readAt: timestamp.addingTimeInterval(-120)
    )
    #expect(try await store.readStates(viewerDid: viewerDid, entries: [bItem])[b] == false)
    let staleBulkCounters = try await store.fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationId]
    )
    #expect(staleBulkCounters.first?.unreadCount == 2)

    _ = try await store.markAllReadCounters(
      viewerDid: viewerDid,
      scopes: [scope],
      readAt: timestamp.addingTimeInterval(2)
    )
    #expect(try await store.readStates(viewerDid: viewerDid, entries: [bItem])[b] == true)
    let newerBulkCounters = try await store.fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: [publicationId]
    )
    #expect(newerBulkCounters.first?.unreadCount == 0)
    #expect(
      try await store.readBoundary(viewerDid: viewerDid, publicationId: publicationId)?.entryId
        == "at://did:plc:author/site.standard.document/c"
    )
  }
}
