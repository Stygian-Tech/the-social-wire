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
}
