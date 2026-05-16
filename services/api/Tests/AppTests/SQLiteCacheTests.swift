import Foundation
import Logging
import Testing

@testable import App

// MARK: - SQLiteCache

@Suite("SQLiteCache")
struct SQLiteCacheTests {

  /// Creates a fresh SQLiteCache backed by a per-test temp file.
  ///
  /// `DatabasePool` opens multiple read connections, so SQLite's `:memory:` path
  /// does not work (each connection gets its own empty DB). We use a temp file with
  /// a unique name instead; the file is left for the OS to clean up.
  private func makeCache() throws -> SQLiteCache {
    var logger = Logger(label: "test.sqlite")
    logger.logLevel = .warning
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-test-\(UUID().uuidString).sqlite")
      .path
    return try SQLiteCache(path: path, logger: logger)
  }

  // MARK: - Discovery cache

  @Test("returns nil when no publications cached")
  func returnsNilWhenEmpty() async throws {
    let cache = try makeCache()
    let result = try await cache.cachedPublications(for: "did:plc:test")
    #expect(result == nil)
  }

  @Test("stores and retrieves publications")
  func storesAndRetrievesPublications() async throws {
    let cache = try makeCache()

    let pubs: [DiscoveredPublication] = [
      DiscoveredPublication(
        publicationId: "at://did:plc:alice/site.standard.entry/abc",
        authorDid:     "did:plc:alice",
        authorHandle:  "alice.bsky.social",
        title:         "Alice's Blog",
        avatarUrl:     nil,
        discoveredAt:  Date()
      ),
      DiscoveredPublication(
        publicationId: "at://did:plc:bob/site.standard.entry/xyz",
        authorDid:     "did:plc:bob",
        authorHandle:  "bob.bsky.social",
        title:         "Bob's Newsletter",
        avatarUrl:     "https://cdn.bsky.app/bob.jpg",
        discoveredAt:  Date()
      ),
    ]

    try await cache.storePublications(pubs, for: "did:plc:user")

    let result = try await cache.cachedPublications(for: "did:plc:user")
    try #require(result != nil)
    #expect(result!.publications.count == 2)
    #expect(result!.publications.map(\.authorDid).contains("did:plc:alice"))
    #expect(result!.publications.map(\.authorDid).contains("did:plc:bob"))
  }

  @Test("isolates cache per user DID")
  func isolatesPerUserDID() async throws {
    let cache = try makeCache()

    let pub = DiscoveredPublication(
      publicationId: "at://did:plc:alice/site.standard.entry/abc",
      authorDid: "did:plc:alice",
      authorHandle: "alice.bsky.social",
      title: "Alice's Blog",
      avatarUrl: nil,
      discoveredAt: Date()
    )

    try await cache.storePublications([pub], for: "did:plc:user1")

    // A different user should see nothing
    let other = try await cache.cachedPublications(for: "did:plc:user2")
    #expect(other == nil)

    // The original user still sees their cache
    let same = try await cache.cachedPublications(for: "did:plc:user1")
    #expect(same?.publications.count == 1)
  }

  @Test("replaces publications on re-store")
  func replacesOnRestore() async throws {
    let cache = try makeCache()
    let did = "did:plc:user"

    let first = DiscoveredPublication(
      publicationId: "at://did:plc:alice/site.standard.entry/abc",
      authorDid: "did:plc:alice", authorHandle: nil,
      title: "Alice", avatarUrl: nil, discoveredAt: Date()
    )
    try await cache.storePublications([first], for: did)

    let second = DiscoveredPublication(
      publicationId: "at://did:plc:bob/site.standard.entry/xyz",
      authorDid: "did:plc:bob", authorHandle: nil,
      title: "Bob", avatarUrl: nil, discoveredAt: Date()
    )
    try await cache.storePublications([second], for: did)

    let result = try await cache.cachedPublications(for: did)
    // Should only contain the second store's results
    try #require(result != nil)
    #expect(result!.publications.count == 1)
    #expect(result!.publications[0].authorDid == "did:plc:bob")
  }

  // MARK: - Entry cache

  @Test("returns nil when entry not cached")
  func returnsNilForMissingEntry() async throws {
    let cache = try makeCache()
    let result = try await cache.cachedEntry(for: "at://did:plc:alice/site.standard.entry/missing")
    #expect(result == nil)
  }

  @Test("stores and retrieves entry detail")
  func storesAndRetrievesEntry() async throws {
    let cache = try makeCache()

    let entry = EntryDetail(
      entryId:     "at://did:plc:alice/site.standard.entry/abc",
      title:       "Hello World",
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      contentHtml: "<p>Hello <strong>world</strong>!</p>",
      originalUrl: "https://alice.example.com/hello"
    )

    try await cache.storeEntry(entry)

    let result = try await cache.cachedEntry(for: entry.entryId)
    try #require(result != nil)
    #expect(result!.entryId == entry.entryId)
    #expect(result!.title == "Hello World")
    #expect(result!.contentHtml == "<p>Hello <strong>world</strong>!</p>")
    #expect(result!.originalUrl == "https://alice.example.com/hello")
  }

  @Test("updates entry on upsert")
  func updatesEntryOnUpsert() async throws {
    let cache = try makeCache()
    let id = "at://did:plc:alice/site.standard.entry/abc"

    let v1 = EntryDetail(
      entryId: id, title: "v1", publishedAt: Date(),
      contentHtml: "<p>old</p>", originalUrl: nil
    )
    try await cache.storeEntry(v1)

    let v2 = EntryDetail(
      entryId: id, title: "v2", publishedAt: Date(),
      contentHtml: "<p>new</p>", originalUrl: "https://example.com/new"
    )
    try await cache.storeEntry(v2)

    let result = try await cache.cachedEntry(for: id)
    try #require(result != nil)
    #expect(result!.title == "v2")
    #expect(result!.contentHtml == "<p>new</p>")
    #expect(result!.originalUrl == "https://example.com/new")
  }

  @Test("stores and retrieves canonical PDS record cache payloads")
  func pdsRecordCacheStoresJSON() async throws {
    let cache = try makeCache()
    try await cache.storePdsRepoRecordPayload(
      ownerDid: "did:plc:alice",
      scopeKey: "com.example.collection:rkey123",
      cid: "bafyx",
      jsonBody: #"{"cid":"bafyx","value":{"x":1}}"#,
      cachedAt: Date(),
      expiresAt: Date().addingTimeInterval(60)
    )

    let warmed = try await cache.cachedPdsRepoRecord(ownerDid: "did:plc:alice", scopeKey: "com.example.collection:rkey123")
    try #require(warmed != nil)
    #expect(warmed!.cid == "bafyx")
    #expect(warmed!.jsonBody.contains("\"x\":1"))
  }
}
