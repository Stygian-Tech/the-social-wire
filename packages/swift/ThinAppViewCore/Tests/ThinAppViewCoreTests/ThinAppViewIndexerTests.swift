import Foundation
import Logging
import Testing

@testable import ThinAppViewCore

@Suite("ThinAppViewIndexer")
struct ThinAppViewIndexerTests {
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

  @Test("indexes read state commit into read_marks")
  func indexesReadState() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-read-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let logger = Logger(label: "indexer.test")
    let store = try SQLiteThinAppViewStore(path: dbPath, logger: logger)
    let config = ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"])
    let indexer = ThinAppViewIndexer(store: store, config: config, logger: logger)

    let subject = "at://did:plc:author/site.standard.document/abc"
    let record: [String: Any] = [
      "subjectUri": subject,
      "readAt": "2026-05-19T12:00:00.000Z",
    ]
    let recordJSON = try JSONSerialization.data(withJSONObject: record)

    try await indexer.handleCommit(
      repoDid: "did:plc:viewer",
      collection: ThinAppViewConfig.readStateCollection,
      rkey: "key1",
      cid: "bafyread",
      recordJSON: recordJSON,
      operation: "create"
    )

    let unread = try await store.listEntries(
      viewerDid: "did:plc:viewer",
      authorDid: "did:plc:author",
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [],
      filter: .unread,
      cursor: nil,
      limit: 10
    )
    #expect(unread.entries.isEmpty)
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
  }
}
