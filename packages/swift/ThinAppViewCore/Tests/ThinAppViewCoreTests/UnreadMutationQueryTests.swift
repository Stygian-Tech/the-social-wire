import Foundation
import Logging
import Testing

@testable import ThinAppViewCore

@Suite("Unread mutation queries")
struct UnreadMutationQueryTests {
  @Test("Sparse unread records paginate without losing hidden URL duplicates")
  func sparseUnreadPagination() async throws {
    try await Self.withSQLite { store in
      try await Self.verifySparseUnreadPagination(store: store, prefix: "did:plc:sparse")
    }
  }

  @Test("Ad hoc overlapping scopes preserve the first scope's read floor and tuple ordering")
  func overlappingScopeReadFloors() async throws {
    try await Self.withSQLite { store in
      try await Self.verifyOverlappingScopeReadFloors(store: store, prefix: "did:plc:floors")
    }
  }

  @Test("A publication floor without a record URI includes the entire timestamp")
  func timestampOnlyReadFloor() async throws {
    try await Self.withSQLite { store in
      try await Self.verifyTimestampOnlyReadFloor(store: store, prefix: "did:plc:timestamp")
    }
  }

  static func verifySparseUnreadPagination(store: any ThinAppViewStore, prefix: String) async throws {
    let viewer = "\(prefix)-read-viewer"
    let otherViewer = "\(prefix)-other-read-viewer"
    let author = "\(prefix)-read-author"
    let publication = "at://\(author)/site.standard.publication/main"
    let scope = makeScope(viewer: viewer, author: author, publicationId: publication, site: publication)
    let timestamp = Date(timeIntervalSince1970: 4_102_444_800)
    let unreadIndices: Set<Int> = [4, 220, 479]
    var readIds: [String] = []
    var unreadIds: [String] = []
    // More than a full legacy scan batch separates the oldest unread record from the newest.
    for index in 0..<480 {
      let id = "at://\(author)/site.standard.document/\(String(format: "%04d", index))"
      try await store.upsertContentItem(IndexedContentItem(
        uri: id, cid: "fixture", authorDid: author, collection: "site.standard.document",
        createdAt: timestamp.addingTimeInterval(Double(index)), indexedAt: timestamp,
        publicationSite: publication,
        render: ContentRenderFields(
          title: id,
          // Published dates deliberately disagree with feed order: cursors use created_at.
          publishedAt: ISO8601DateFormatter().string(from: timestamp.addingTimeInterval(-Double(index))),
          articleUrl: "https://example.com/shared-story"
        ),
        expiresAt: timestamp.addingTimeInterval(86_400)
      ))
      if unreadIndices.contains(index) { unreadIds.append(id) } else { readIds.append(id) }
    }
    try await store.upsertReadMarks(viewerDid: viewer, subjectUris: readIds, createdAt: timestamp)
    try await store.upsertReadMarks(viewerDid: otherViewer, subjectUris: unreadIds, createdAt: timestamp)
    // A newer expired row must not consume the page or supply its cursor.
    try await store.upsertContentItem(IndexedContentItem(
      uri: "at://\(author)/site.standard.document/expired", cid: "fixture", authorDid: author,
      collection: "site.standard.document", createdAt: timestamp.addingTimeInterval(1_000),
      indexedAt: timestamp, publicationSite: publication,
      render: ContentRenderFields(title: "Expired", publishedAt: "2100-01-01T00:00:00Z"), expiresAt: Date(timeIntervalSince1970: 1)
    ))
    try await store.upsertContentItem(IndexedContentItem(
      uri: "at://\(author)/site.standard.document/outside", cid: "fixture", authorDid: author,
      collection: "site.standard.document", createdAt: timestamp.addingTimeInterval(1_000),
      indexedAt: timestamp, publicationSite: "https://example.com/another-publication",
      render: ContentRenderFields(title: "Outside", publishedAt: "2100-01-01T00:00:00Z"), expiresAt: timestamp.addingTimeInterval(86_400)
    ))

    let first = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [scope], cursor: nil, limit: 2)
    #expect(first.entries.map(\.entryId) == Array(unreadIds.reversed().prefix(2)))
    #expect(first.entries.allSatisfy { $0.publicationId == publication })
    let cursor = try #require(first.cursor)
    let second = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [scope], cursor: cursor, limit: 2)
    #expect(second.entries.map(\.entryId) == [unreadIds[0]])
    #expect(second.cursor == nil)
    #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: unreadIds[0]) == false)

    let empty = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [], cursor: nil, limit: 2)
    #expect(empty.entries.isEmpty)
    #expect(empty.cursor == nil)
  }

  static func verifyOverlappingScopeReadFloors(store: any ThinAppViewStore, prefix: String) async throws {
    let viewer = "\(prefix)-read-viewer"
    let otherViewer = "\(prefix)-other-read-viewer"
    let author = "\(prefix)-read-author"
    let site = "at://\(author)/site.standard.publication/main"
    let firstId = "at://\(author)/site.standard.publication/a"
    let lastId = "at://\(author)/site.standard.publication/z"
    let firstScope = makeScope(viewer: viewer, author: author, publicationId: firstId, site: site)
    let lastScope = makeScope(viewer: viewer, author: author, publicationId: lastId, site: site)
    let timestamp = Date(timeIntervalSince1970: 4_102_444_800)
    func id(_ suffix: String) -> String { "at://\(author)/site.standard.document/\(suffix)" }
    func insert(_ suffix: String, offset: TimeInterval = 0) async throws {
      try await store.upsertContentItem(IndexedContentItem(
        uri: id(suffix), cid: "fixture", authorDid: author, collection: "site.standard.document",
        createdAt: timestamp.addingTimeInterval(offset), indexedAt: timestamp, publicationSite: site,
        render: ContentRenderFields(title: suffix, publishedAt: "2100-01-01T00:00:00Z"), expiresAt: timestamp.addingTimeInterval(86_400)
      ))
    }
    try await insert("a")
    try await insert("b")
    _ = try await store.markAllReadCounters(
      viewerDid: viewer,
      scopes: [PublicationUnreadScope(
        publicationId: firstId, authorDid: author, publicationAtUri: site,
        publicationScopeAtUris: [site], publicationSiteUrls: [])],
      readAt: timestamp.addingTimeInterval(1)
    )
    #expect(try await store.readBoundary(viewerDid: viewer, publicationId: firstId)?.entryId == id("b"))
    try await insert("older", offset: -1)
    try await insert("c")
    try await insert("newer", offset: 1)
    try await store.markEntryUnread(viewerDid: viewer, subjectUri: id("a"), createdAt: timestamp)
    try await store.markEntryUnread(viewerDid: viewer, subjectUri: id("b"), createdAt: timestamp)
    try await store.upsertReadMark(viewerDid: viewer, subjectUri: id("b"), createdAt: timestamp)
    try await store.upsertReadMark(viewerDid: otherViewer, subjectUri: id("c"), createdAt: timestamp)

    // Neither supplied scope was persisted, and the call deliberately reverses publication order.
    let first = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [lastScope, firstScope], cursor: nil, limit: 2)
    #expect(first.entries.map(\.entryId) == [id("newer"), id("c")])
    #expect(first.entries.allSatisfy { $0.publicationId == firstId })
    let nextCursor = try #require(first.cursor)
    let second = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [lastScope, firstScope], cursor: nextCursor, limit: 2)
    #expect(second.entries.map(\.entryId) == [id("a")])
    #expect(second.entries.first?.publicationId == firstId)
    #expect(second.cursor == nil)

    // A floor on a later matching publication must not suppress rows owned by the first match.
    let earlierId = "at://\(author)/site.standard.publication/0"
    let earlierScope = makeScope(viewer: viewer, author: author, publicationId: earlierId, site: site)
    let noFloor = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [lastScope, firstScope, earlierScope], cursor: nil, limit: 100)
    #expect(noFloor.entries.map(\.entryId) == [id("newer"), id("c"), id("a"), id("older")])
    #expect(noFloor.entries.allSatisfy { $0.publicationId == earlierId })

    let other = try await store.listUnreadEntriesForReadMutation(
      viewerDid: otherViewer, scopes: [firstScope, lastScope], cursor: nil, limit: 100)
    #expect(other.entries.map(\.entryId) == [id("newer"), id("b"), id("a"), id("older")])
  }

  static func verifyTimestampOnlyReadFloor(store: any ThinAppViewStore, prefix: String) async throws {
    let viewer = "\(prefix)-read-viewer"
    let author = "\(prefix)-read-author"
    let publication = "at://\(author)/site.standard.publication/main"
    let timestamp = Date(timeIntervalSince1970: 4_102_444_800)
    let scope = makeScope(viewer: viewer, author: author, publicationId: publication, site: publication)
    _ = try await store.markAllReadCounters(
      viewerDid: viewer,
      scopes: [PublicationUnreadScope(
        publicationId: publication, authorDid: author, publicationAtUri: publication,
        publicationScopeAtUris: [], publicationSiteUrls: [])],
      readAt: timestamp
    )
    let boundary = try #require(try await store.readBoundary(viewerDid: viewer, publicationId: publication))
    #expect(boundary.entryId == nil)
    for offset in [-1, 0, 1] {
      try await store.upsertContentItem(IndexedContentItem(
        uri: "at://\(author)/site.standard.document/\(offset)", cid: "fixture", authorDid: author,
        collection: "site.standard.document", createdAt: timestamp.addingTimeInterval(Double(offset)),
        indexedAt: timestamp, publicationSite: publication, render: ContentRenderFields(title: "\(offset)", publishedAt: "2100-01-01T00:00:00Z"),
        expiresAt: timestamp.addingTimeInterval(86_400)
      ))
    }
    let page = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [scope], cursor: nil, limit: 100)
    #expect(page.entries.map(\.entryId) == ["at://\(author)/site.standard.document/1"])
    #expect(page.cursor == nil)
  }

  @Test("Query-specific feed scopes exclude queryless and other-format rows")
  func querySpecificFeedScope() async throws {
    try await Self.withSQLite { store in
      try await Self.verifyQuerySpecificFeedScope(store: store, prefix: "did:plc:query")
    }
  }

  static func verifyQuerySpecificFeedScope(store: any ThinAppViewStore, prefix: String) async throws {
    let viewer = "\(prefix)-read-viewer"
    let author = "\(prefix)-read-author"
    let feed = "https://example.com/feed?format=rss"
    let timestamp = Date(timeIntervalSince1970: 4_102_444_800)
    let scope = AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewer, publicationId: feed, authorDid: author, publicationAtUri: nil,
      publicationScopeAtUris: [], publicationSiteUrls: [feed], sectionKeys: [])
    for (index, site) in [feed, "https://example.com/feed", "https://example.com/feed?format=atom"].enumerated() {
      try await store.upsertContentItem(IndexedContentItem(
        uri: "at://\(author)/site.standard.document/\(index)", cid: "fixture", authorDid: author,
        collection: "site.standard.document", createdAt: timestamp.addingTimeInterval(Double(index)),
        indexedAt: timestamp, publicationSite: site,
        render: ContentRenderFields(title: site, publishedAt: "2100-01-01T00:00:00Z"),
        expiresAt: timestamp.addingTimeInterval(86_400)
      ))
    }
    let page = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [scope], cursor: nil, limit: 1)
    #expect(page.entries.map(\.entryId) == ["at://\(author)/site.standard.document/0"])
    #expect(page.cursor == nil)
  }

  @Test("Specific site aliases retain their read floor ahead of broad author scopes")
  func mixedBroadAndSpecificScopes() async throws {
    try await Self.withSQLite { store in
      try await Self.verifyMixedBroadAndSpecificScopes(store: store, prefix: "did:plc:mixed")
    }
  }

  static func verifyMixedBroadAndSpecificScopes(store: any ThinAppViewStore, prefix: String) async throws {
    let viewer = "\(prefix)-read-viewer"
    let author = "\(prefix)-read-author"
    let specificId = "at://\(author)/site.standard.publication/a"
    let broadId = "at://\(author)/site.standard.publication/z"
    let canonicalSite = "https://example.com/publication"
    let storedSite = canonicalSite + "/"
    let timestamp = Date(timeIntervalSince1970: 4_102_444_800)
    let specific = AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewer, publicationId: specificId, authorDid: author, publicationAtUri: nil,
      publicationScopeAtUris: [], publicationSiteUrls: [canonicalSite], sectionKeys: [])
    let broad = AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewer, publicationId: broadId, authorDid: author, publicationAtUri: nil,
      publicationScopeAtUris: [], publicationSiteUrls: [], sectionKeys: [])
    #expect(AppViewUnreadCounterSupport.contentMatchesScope(
      authorDid: author, publicationSite: storedSite, scope: specific))
    _ = try await store.markAllReadCounters(
      viewerDid: viewer,
      scopes: [PublicationUnreadScope(
        publicationId: specificId, authorDid: author, publicationAtUri: nil,
        publicationScopeAtUris: [], publicationSiteUrls: [canonicalSite])],
      readAt: timestamp
    )
    func id(_ title: String) -> String { "at://\(author)/site.standard.document/\(title)" }
    let rows: [(String, String?, TimeInterval)] = [
      ("older-alias", storedSite, -2), ("newer-alias", storedSite, 1), ("no-site", nil, -1),
    ]
    for (title, site, offset) in rows {
      try await store.upsertContentItem(IndexedContentItem(
        uri: id(title), cid: "fixture", authorDid: author, collection: "site.standard.document",
        createdAt: timestamp.addingTimeInterval(offset), indexedAt: timestamp, publicationSite: site,
        render: ContentRenderFields(title: title, publishedAt: "2100-01-01T00:00:00Z"),
        expiresAt: timestamp.addingTimeInterval(86_400)
      ))
    }
    let page = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [broad, specific], cursor: nil, limit: 100)
    #expect(page.entries.map(\.entryId) == [id("newer-alias"), id("no-site")])
    #expect(page.entries.map(\.publicationId) == [specificId, broadId])
    #expect(page.cursor == nil)

    try await store.markEntryUnread(viewerDid: viewer, subjectUri: id("older-alias"), createdAt: timestamp)
    let overridden = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [broad, specific], cursor: nil, limit: 100)
    #expect(overridden.entries.map(\.entryId) == [id("newer-alias"), id("no-site"), id("older-alias")])
    #expect(overridden.entries.map(\.publicationId) == [specificId, broadId, specificId])

    // Alias discovery for one broad author must not widen another author's coarse scope.
    let otherAuthor = "\(prefix)-other-read-author"
    let otherSpecific = AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewer, publicationId: "https://example.com/other-publication", authorDid: otherAuthor,
      publicationAtUri: nil, publicationScopeAtUris: [], publicationSiteUrls: [canonicalSite], sectionKeys: [])
    let otherId = "at://\(otherAuthor)/site.standard.document/alias"
    try await store.upsertContentItem(IndexedContentItem(
      uri: otherId, cid: "fixture", authorDid: otherAuthor, collection: "site.standard.document",
      createdAt: timestamp, indexedAt: timestamp, publicationSite: storedSite,
      render: ContentRenderFields(title: "Other Alias", publishedAt: "2100-01-01T00:00:00Z"),
      expiresAt: timestamp.addingTimeInterval(86_400)
    ))
    let scoped = try await store.listUnreadEntriesForReadMutation(
      viewerDid: viewer, scopes: [broad, specific, otherSpecific], cursor: nil, limit: 100)
    #expect(scoped.entries.map(\.entryId) == overridden.entries.map(\.entryId))
  }

  @Test("Minimal read mutation pages preserve date fallback and tie cursors with large display payloads")
  func minimalProjection() async throws {
    try await Self.withSQLite { store in
      try await Self.verifyMinimalProjection(store: store, prefix: "did:plc:minimal")
    }
  }

  static func verifyMinimalProjection(store: any ThinAppViewStore, prefix: String) async throws {
    let viewer = "\(prefix)-read-viewer"
    let author = "\(prefix)-read-author"
    let publication = "at://\(author)/site.standard.publication/main"
    let timestamp = Date(timeIntervalSince1970: 4_102_444_800)
    let scope = makeScope(viewer: viewer, author: author, publicationId: publication, site: publication)
    let payload = String(repeating: "display-only &amp; ", count: 4_000)
    for (key, published) in [("a", "2099-12-31T00:00:00Z"), ("b", "malformed"), ("c", "")] {
      try await store.upsertContentItem(IndexedContentItem(
        uri: "at://\(author)/site.standard.document/\(key)", cid: "fixture", authorDid: author,
        collection: "site.standard.document", createdAt: timestamp, indexedAt: timestamp,
        publicationSite: publication,
        render: ContentRenderFields(title: payload, publishedAt: published, summary: payload,
          thumbnailUrl: "https://example.com/large.jpg", contentHtml: payload),
        expiresAt: timestamp.addingTimeInterval(86_400)
      ))
    }
    var cursor: String?
    var result: [UnreadReadMutationEntry] = []
    repeat {
      let page = try await store.listUnreadEntriesForReadMutation(
        viewerDid: viewer, scopes: [scope], cursor: cursor, limit: 1)
      result.append(contentsOf: page.entries)
      cursor = page.cursor
    } while cursor != nil
    #expect(result.map(\.entryId) == ["c", "b", "a"].map { "at://\(author)/site.standard.document/\($0)" })
    #expect(result.map(\.publishedAt) == [timestamp, timestamp, timestamp.addingTimeInterval(-86_400)])
    #expect(result.allSatisfy { $0.feedPositionAt == timestamp && $0.publicationId == publication })
  }

  @Test("SQLite read-age pages retain every record across the bounded larger page")
  func largerMutationPages() async throws {
    try await Self.withSQLite { store in
      let viewer = "did:plc:wide-read-viewer"
      let author = "did:plc:wide-read-author"
      let publication = "at://\(author)/site.standard.publication/main"
      let prefix = "at://\(author)/site.standard.document/"
      let timestamp = Date(timeIntervalSince1970: 4_102_444_800)
      let scope = Self.makeScope(viewer: viewer, author: author, publicationId: publication, site: publication)
      for index in 1...1007 {
        try await store.upsertContentItem(IndexedContentItem(
          uri: prefix + String(format: "%04d", index), cid: "fixture", authorDid: author,
          collection: "site.standard.document", createdAt: timestamp, indexedAt: timestamp,
          publicationSite: publication,
          render: ContentRenderFields(title: "entry", publishedAt: "malformed",
            articleUrl: "https://example.com/shared-story"),
          expiresAt: timestamp.addingTimeInterval(86_400)))
      }
      func snapshot(limit: Int) async throws -> [UnreadReadMutationEntry] {
        var cursor: String?
        var entries: [UnreadReadMutationEntry] = []
        repeat {
          let page = try await store.listUnreadEntriesForReadMutation(
            viewerDid: viewer, scopes: [scope], cursor: cursor, limit: limit)
          entries.append(contentsOf: page.entries)
          cursor = page.cursor
        } while cursor != nil
        return entries
      }
      let original = try await snapshot(limit: 100)
      let larger = try await snapshot(limit: 1000)
      #expect(larger == original)
      #expect(larger.count == 1007)
      #expect(Set(larger.map(\.entryId)).count == 1007)
      #expect(larger.allSatisfy { $0.publishedAt == timestamp && $0.publicationId == publication })
      let capped = try await store.listUnreadEntriesForReadMutation(
        viewerDid: viewer, scopes: [scope], cursor: nil, limit: 10_000)
      #expect(capped.entries.count == 1000)
      #expect(capped.entries == Array(larger.prefix(1000)))
      #expect(ThinAppViewCursor.decode(try #require(capped.cursor))?.uri == prefix + "0008")
    }
  }

  private static func makeScope(
    viewer: String, author: String, publicationId: String, site: String
  ) -> AppViewPublicationScope {
    AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewer, publicationId: publicationId, authorDid: author,
      publicationAtUri: site, publicationScopeAtUris: [site], publicationSiteUrls: [], sectionKeys: [])
  }

  private static func withSQLite(
    _ body: (SQLiteThinAppViewStore) async throws -> Void
  ) async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-unread-mutation-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteThinAppViewStore(path: path, logger: Logger(label: "appview.test"))
    try await body(store)
  }
}
