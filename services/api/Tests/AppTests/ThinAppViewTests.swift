import Foundation
import Testing

@testable import App

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
      filter: .unread,
      cursor: nil,
      limit: 10
    )
    #expect(unread.entries.count == 1)
    #expect(unread.entries.first?.entryId.contains("/two") == true)
  }
}

import Logging
