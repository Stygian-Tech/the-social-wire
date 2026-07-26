import Foundation
import GatewayCore
import Testing

@Suite("Bootstrap stream NDJSON")
struct BootstrapStreamNDJSONTests {
  @Test("encodeLine appends newline and round-trips selectedPublication")
  func encodeLineAppendsNewline() throws {
    let event = AppViewBootstrapStreamEvent.selectedPublication(publicationId: "pub-a")
    let data = try AppViewBootstrapStreamNDJSON.encodeLine(event)
    #expect(data.last == 0x0A)

    let line = String(decoding: data.dropLast(), as: UTF8.self)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AppViewBootstrapStreamEvent.self, from: Data(line.utf8))
    #expect(decoded.kind == .selectedPublication)
    #expect(decoded.selectedPublication?.publicationId == "pub-a")
  }

  @Test("sidebarSection round-trips with zero unread replacement")
  func sidebarSectionRoundTrips() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let row = SidebarPublicationRow(
      publicationId: "pub-a",
      subscriptionPublicationId: nil,
      authorDid: "did:plc:alice",
      authorHandle: "alice.example",
      title: "Alice",
      iconUrl: nil,
      avatarUrl: nil,
      discoveredAt: now,
      appViewScope: PublicationAppViewScope(
        authorDid: "did:plc:alice",
        publicationAtUri: nil,
        publicationScopeAtUris: [],
        publicationSiteUrls: []
      ),
      unreadCount: 3
    )
    let event = AppViewBootstrapStreamEvent.sidebarSection(
      AppViewBootstrapSidebarSectionPayload(
        sectionKey: "folder:news",
        folderRkey: "news",
        folderUri: "at://did:plc:viewer/app.thesocialwire.folder/news",
        publications: [row],
        unreadCounts: ["pub-a": 0],
        replacePublicationIds: ["pub-a"],
        sectionGeneration: 42,
        refreshedAt: now
      )
    )

    let data = try AppViewBootstrapStreamNDJSON.encodeLine(event)
    let line = String(decoding: data.dropLast(), as: UTF8.self)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AppViewBootstrapStreamEvent.self, from: Data(line.utf8))

    #expect(decoded.kind == .sidebarSection)
    #expect(decoded.sidebarSection?.sectionKey == "folder:news")
    #expect(decoded.sidebarSection?.unreadCounts?["pub-a"] == 0)
    #expect(decoded.sidebarSection?.replacePublicationIds == ["pub-a"])
    #expect(decoded.sidebarSection?.sectionGeneration == 42)
  }

  @Test("unreadCounts round-trips generation metadata")
  func unreadCountsMetadataRoundTrips() throws {
    let countedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let event = AppViewBootstrapStreamEvent.unreadCounts(
      ["pub-a": 3],
      replacePublicationIds: ["pub-a"],
      generation: 99,
      accuracy: "exact",
      countedAt: countedAt
    )

    let data = try AppViewBootstrapStreamNDJSON.encodeLine(event)
    let line = String(decoding: data.dropLast(), as: UTF8.self)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AppViewBootstrapStreamEvent.self, from: Data(line.utf8))

    #expect(decoded.kind == .unreadCounts)
    #expect(decoded.unreadCounts?.counts["pub-a"] == 3)
    #expect(decoded.unreadCounts?.generation == 99)
    #expect(decoded.unreadCounts?.accuracy == "exact")
    #expect(decoded.unreadCounts?.countedAt == countedAt)
  }

  @Test("entries page requires and preserves cache provenance")
  func entriesPageProvenanceRoundTrips() throws {
    let cachedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let expiresAt = cachedAt.addingTimeInterval(300)
    let event = AppViewBootstrapStreamEvent.entriesPage(
      AppViewBootstrapEntriesPagePayload(
        publicationId: "pub-a",
        entries: [],
        cursor: nil,
        source: .projectionCache,
        cachedAt: cachedAt,
        expiresAt: expiresAt
      )
    )

    let data = try AppViewBootstrapStreamNDJSON.encodeLine(event)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
      AppViewBootstrapStreamEvent.self,
      from: Data(data.dropLast())
    )
    #expect(decoded.entriesPage?.source == .projectionCache)
    #expect(decoded.entriesPage?.cachedAt == cachedAt)
    #expect(decoded.entriesPage?.expiresAt == expiresAt)

    let ungrounded = #"{"kind":"entriesPage","entriesPage":{"publicationId":"pub-a","entries":[]}}"#
    #expect(throws: DecodingError.self) {
      try decoder.decode(AppViewBootstrapStreamEvent.self, from: Data(ungrounded.utf8))
    }
  }

  @Test("done provenance distinguishes cached evidence and remains backward-compatible")
  func doneProvenanceRoundTrips() throws {
    let refreshedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let event = AppViewBootstrapStreamEvent.done(
      refreshedAt: refreshedAt,
      source: .projectionCache
    )
    let encoded = try AppViewBootstrapStreamNDJSON.encodeLine(event)
    let line = Data(encoded.dropLast())
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AppViewBootstrapStreamEvent.self, from: line)
    #expect(decoded.done?.refreshedAt == refreshedAt)
    #expect(decoded.done?.source == .projectionCache)

    let legacy = #"{"kind":"done","done":{"refreshedAt":"2027-01-15T08:00:00Z"}}"#
    let legacyDecoded = try decoder.decode(
      AppViewBootstrapStreamEvent.self,
      from: Data(legacy.utf8)
    )
    #expect(legacyDecoded.done?.source == nil)

    let unavailable = AppViewBootstrapStreamEvent.done(
      refreshedAt: refreshedAt,
      source: .unavailable
    )
    let unavailableLine = try AppViewBootstrapStreamNDJSON.encodeLine(unavailable)
    let unavailableDecoded = try decoder.decode(
      AppViewBootstrapStreamEvent.self,
      from: Data(unavailableLine.dropLast())
    )
    #expect(unavailableDecoded.done?.source == .unavailable)
  }
}
