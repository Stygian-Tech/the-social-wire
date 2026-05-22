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
}
