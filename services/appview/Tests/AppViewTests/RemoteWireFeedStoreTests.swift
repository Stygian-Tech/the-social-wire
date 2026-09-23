import Foundation
import Testing
import WireCore
@testable import AppView

@Suite("The Wire remote corpus store")
struct RemoteWireFeedStoreTests {
  private let cursorSecret = String(repeating: "c", count: 32)
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("applies viewer moderation locally to simplified fallback")
  func fallbackModeration() async throws {
    let cache = WireViewerModerationCache()
    await cache.store(
      WireViewerModerationSnapshot(
        blockedDIDs: ["did:plc:blocked"],
        mutedDIDs: [],
        mutedWords: ["spoiler"],
        fetchedAt: now
      ),
      viewerDID: "did:plc:viewer"
    )
    let response = try encodedResponse(
      WireCorpusPage(
        generationID: "fallback-1",
        generatedAt: now,
        language: "en",
        source: .simplifiedFallback,
        degraded: true,
        rows: [
          WireCorpusRow(
            ordinal: 0,
            item: item(id: "blocked", title: "Blocked", actor: "did:plc:blocked"),
            sourceActorKey: "did:plc:blocked"
          ),
          WireCorpusRow(
            ordinal: 1,
            item: item(id: "muted-word", title: "A spoiler", actor: nil),
            sourceActorKey: nil
          ),
          WireCorpusRow(
            ordinal: 2,
            item: item(id: "safe", title: "Safe story", actor: nil),
            sourceActorKey: nil
          ),
        ],
        exhausted: true
      )
    )
    let transport = StubWireCorpusTransport(responses: [response])
    let store = try RemoteWireFeedStore(
      transport: transport,
      cursorSecret: cursorSecret,
      mode: .visible,
      moderationCache: cache
    )
    let page = try await store.getFeed(
      cursor: nil,
      limit: 10,
      language: "en-US",
      viewerDid: "did:plc:viewer",
      now: now
    )
    #expect(page.items.map(\.itemID) == ["safe"])
    #expect(page.cursor == nil)
    let targets = await transport.targets
    #expect(targets.count == 1)
    #expect(!targets[0].contains("viewer"))
  }

  @Test("mints a local generation cursor after the last delivered row")
  func localCursor() async throws {
    let generationID = UUID().uuidString.lowercased()
    let response = try encodedResponse(
      WireCorpusPage(
        generationID: generationID,
        generatedAt: now,
        language: "und",
        source: .ranked,
        degraded: false,
        rows: [
          WireCorpusRow(ordinal: 7, item: item(id: "one", title: "One", actor: nil), sourceActorKey: nil),
          WireCorpusRow(ordinal: 8, item: item(id: "two", title: "Two", actor: nil), sourceActorKey: nil),
        ],
        exhausted: true
      )
    )
    let store = try RemoteWireFeedStore(
      transport: StubWireCorpusTransport(responses: [response]),
      cursorSecret: cursorSecret,
      mode: .visible,
      moderationCache: WireViewerModerationCache()
    )
    let page = try await store.getFeed(
      cursor: nil,
      limit: 1,
      language: nil,
      viewerDid: nil,
      now: now
    )
    let cursor = try #require(page.cursor)
    let decoded = try WireCursorCodec(secret: cursorSecret).decode(cursor)
    #expect(decoded.generationID == generationID)
    #expect(decoded.nextOrdinal == 8)
  }

  @Test("rejects a global corpus response for an exact locale request")
  func rejectsGlobalLocaleFallback() async throws {
    let response = try encodedResponse(
      WireCorpusPage(
        generationID: UUID().uuidString.lowercased(),
        generatedAt: now,
        language: "und",
        source: .ranked,
        degraded: false,
        rows: [],
        exhausted: true
      )
    )
    let store = try RemoteWireFeedStore(
      transport: StubWireCorpusTransport(responses: [response]),
      cursorSecret: cursorSecret,
      mode: .visible,
      moderationCache: WireViewerModerationCache()
    )
    await #expect(throws: WireServingError.self) {
      _ = try await store.getFeed(
        cursor: nil,
        limit: 10,
        language: "en-US",
        viewerDid: nil,
        now: now
      )
    }
  }

  @Test("rejects a cursor minted for a different language")
  func rejectsCrossLanguageCursor() async throws {
    let cursor = try WireCursorCodec(secret: cursorSecret).encode(
      WireCursor(
        generationID: UUID().uuidString.lowercased(),
        language: "und",
        nextOrdinal: 1
      )
    )
    let store = try RemoteWireFeedStore(
      transport: StubWireCorpusTransport(error: StubError.unavailable),
      cursorSecret: cursorSecret,
      mode: .visible,
      moderationCache: WireViewerModerationCache()
    )
    do {
      _ = try await store.getFeed(
        cursor: cursor,
        limit: 10,
        language: "en",
        viewerDid: nil,
        now: now
      )
      Issue.record("Expected a cross-language cursor to be invalid")
    } catch WireServingError.invalidCursor {
      // Exact public contract: malformed request, not an expired scoped cursor.
    } catch {
      Issue.record("Expected invalidCursor, received \(String(reflecting: error))")
    }
  }

  @Test("upstream failure is isolated to The Wire")
  func outage() async throws {
    let store = try RemoteWireFeedStore(
      transport: StubWireCorpusTransport(error: StubError.unavailable),
      cursorSecret: cursorSecret,
      mode: .visible,
      moderationCache: WireViewerModerationCache()
    )
    await #expect(throws: WireServingError.self) {
      _ = try await store.getFeed(
        cursor: nil,
        limit: 10,
        language: nil,
        viewerDid: nil,
        now: now
      )
    }
  }

  @Test("edition mints a getWire continuation at the first fifty-story boundary")
  func editionContinuation() async throws {
    let generationID = UUID().uuidString.lowercased()
    let edition = WireEditionAssembler.assemble(
      generationID: generationID,
      generatedAt: now,
      language: "en",
      cursor: "50",
      source: .ranked,
      degraded: false,
      rankedItems: [item(id: "one", title: "One", actor: nil)]
    )
    let transport = StubWireCorpusTransport(responses: [try encodedResponse(edition)])
    let store = try RemoteWireFeedStore(
      transport: transport,
      cursorSecret: cursorSecret,
      mode: .visible,
      moderationCache: WireViewerModerationCache()
    )
    let result = try await store.getEdition(
      language: "en-US",
      region: .outsideUnitedStates,
      viewerDid: nil,
      now: now
    )
    let cursor = try #require(result.cursor)
    let decoded = try WireCursorCodec(secret: cursorSecret).decode(cursor)
    #expect(decoded.generationID == generationID)
    #expect(decoded.language == "en")
    #expect(decoded.nextOrdinal == 50)
    #expect(await transport.targets == [
      "/internal/wire/v1/edition?fallbackLimit=5000&language=en&region=outside-us",
    ])
  }

  @Test("regional edition falls back across a staged Corpus Edge rollout")
  func regionalContractFallback() async throws {
    let edition = WireEditionAssembler.assemble(
      generationID: UUID().uuidString.lowercased(),
      generatedAt: now,
      language: "en",
      source: .ranked,
      degraded: false,
      rankedItems: [item(id: "one", title: "One", actor: nil)]
    )
    let transport = StubWireCorpusTransport(responses: [
      WireCorpusTransportResponse(statusCode: 400, contractVersion: 2, body: Data()),
      try encodedResponse(edition),
    ])
    let store = try RemoteWireFeedStore(
      transport: transport,
      cursorSecret: cursorSecret,
      mode: .visible,
      moderationCache: WireViewerModerationCache()
    )

    _ = try await store.getEdition(
      language: "en",
      region: .outsideUnitedStates,
      viewerDid: nil,
      now: now
    )

    #expect(await transport.targets == [
      "/internal/wire/v1/edition?fallbackLimit=5000&language=en&region=outside-us",
      "/internal/wire/v1/edition?language=en",
    ])
  }

  @Test("edition accepts the Circle-compatible Corpus Edge contract")
  func editionAcceptsContractVersionThree() async throws {
    let edition = WireEditionAssembler.assemble(
      generationID: UUID().uuidString.lowercased(),
      generatedAt: now,
      language: "en",
      source: .ranked,
      degraded: false,
      rankedItems: [item(id: "one", title: "One", actor: nil)]
    )
    let store = try RemoteWireFeedStore(
      transport: StubWireCorpusTransport(responses: [
        try encodedResponse(edition, contractVersion: 3)
      ]),
      cursorSecret: cursorSecret,
      mode: .visible,
      moderationCache: WireViewerModerationCache()
    )

    let result = try await store.getEdition(
      language: "en",
      region: nil,
      viewerDid: nil,
      now: now
    )

    #expect(result.language == "en")
  }

  @Test("edition moderates external actor identity without leaking it publicly", arguments: [WirePageSource.ranked, .simplifiedFallback])
  func editionActorModeration(source: WirePageSource) async throws {
    let cache = WireViewerModerationCache()
    await cache.store(WireViewerModerationSnapshot(
      blockedDIDs: ["did:plc:blocked"], mutedDIDs: ["did:plc:muted"], mutedWords: ["spoiler"], fetchedAt: now),
      viewerDID: "did:plc:viewer")
    let stories = [item(id: "blocked", title: "Blocked", actor: nil),
      item(id: "muted", title: "Muted", actor: nil),
      item(id: "word", title: "Spoiler", actor: nil),
      item(id: "safe", title: "Safe", actor: nil)]
    let edition = WireEdition(generationID: UUID().uuidString.lowercased(), generatedAt: now,
      language: "en", cursor: nil, source: source, degraded: source == .simplifiedFallback,
      leadStories: stories,
      publicationPanels: [WireEditionPublicationPanel(publication: WireEditionPublication(
        key: "example.com", id: nil, name: "Example", domain: "example.com", homepageURL: nil, iconURL: nil), stories: stories)],
      storyRails: [WireEditionStoryRail(reason: .widelyDiscussed, stories: stories)], generalStories: stories,
      trendingStories: stories, talkedAboutAccounts: [])
    let corpus = WireCorpusEdition(edition: edition,
      sourceActorKeysByItemID: ["blocked": "did:plc:blocked", "muted": "did:plc:muted"],
      fallbackRows: source == .simplifiedFallback ? stories.enumerated().map { index, item in
        WireCorpusRow(ordinal: index, item: item,
          sourceActorKey: ["blocked": "did:plc:blocked", "muted": "did:plc:muted"][item.itemID])
      } : nil)
    let encoded = try encodedResponse(corpus)
    // Older Edge consumers still see the unchanged flattened edition shape.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(WireEdition.self, from: encoded.body) == edition)
    let store = try RemoteWireFeedStore(transport: StubWireCorpusTransport(responses: [encoded]),
      cursorSecret: cursorSecret, mode: .visible, moderationCache: cache)
    let result = try await store.getEdition(language: "en", region: nil, viewerDid: "did:plc:viewer", now: now)
    #expect(result.leadStories.map(\.itemID) == ["safe"])
    if source == .ranked {
      #expect(result.generalStories.map(\.itemID) == ["safe"])
      #expect(result.trendingStories.map(\.itemID) == ["safe"])
    }
    #expect(result.source == source)
    #expect(result.publicationPanels.isEmpty)
    #expect(result.storyRails.isEmpty)
    let publicJSON = String(decoding: try JSONEncoder().encode(WireEditionResponse(edition: result)), as: UTF8.self)
    #expect(!publicJSON.contains("sourceActorKeysByItemID"))
    #expect(!publicJSON.contains("fallbackRows"))
    #expect(!publicJSON.contains("did:plc:blocked"))
  }

  @Test("signed-in legacy edition fails closed but explicit empty identity is valid")
  func editionIdentityRollout() async throws {
    let cache = WireViewerModerationCache()
    await cache.store(WireViewerModerationSnapshot(blockedDIDs: ["did:plc:blocked"],
      mutedDIDs: [], mutedWords: [], fetchedAt: now), viewerDID: "did:plc:viewer")
    let edition = WireEditionAssembler.assemble(generationID: UUID().uuidString.lowercased(),
      generatedAt: now, language: "en", source: .ranked, degraded: false,
      rankedItems: [item(id: "safe", title: "Safe", actor: nil)])
    let store = try RemoteWireFeedStore(transport: StubWireCorpusTransport(responses: [
      try encodedResponse(edition), try encodedResponse(WireCorpusEdition(edition: edition, sourceActorKeysByItemID: [:]))]),
      cursorSecret: cursorSecret, mode: .visible, moderationCache: cache)
    await #expect(throws: WireServingError.unavailable) {
      try await store.getEdition(language: "en", region: nil, viewerDid: "did:plc:viewer", now: now)
    }
    let result = try await store.getEdition(language: "en", region: nil, viewerDid: "did:plc:viewer", now: now)
    #expect(result.leadStories.map(\.itemID) == ["safe"])
  }

  @Test("fallback scans beyond five hundred muted stories without sharing viewer filtering")
  func fullFallbackModeration() async throws {
    let cache = WireViewerModerationCache()
    await cache.store(WireViewerModerationSnapshot(blockedDIDs: [], mutedDIDs: [],
      mutedWords: ["hidden"], fetchedAt: now), viewerDID: "did:plc:viewer")
    let rows = (0..<501).map { WireCorpusRow(ordinal: $0,
      item: item(id: "muted-\($0)", title: "Hidden", actor: nil), sourceActorKey: nil) }
      + [WireCorpusRow(ordinal: 501, item: item(id: "allowed", title: "Allowed", actor: nil), sourceActorKey: nil)]
    let page = WireCorpusPage(generationID: "fallback-1", generatedAt: now, language: "en",
      source: .simplifiedFallback, degraded: true, rows: rows, exhausted: true)
    let transport = StubWireCorpusTransport(responses: [try encodedResponse(page), try encodedResponse(page)])
    let store = try RemoteWireFeedStore(transport: transport, cursorSecret: cursorSecret,
      mode: .visible, moderationCache: cache)
    let viewer = try await store.getFeed(cursor: nil, limit: 1, language: "en", viewerDid: "did:plc:viewer", now: now)
    let anonymous = try await store.getFeed(cursor: nil, limit: 1, language: "en", viewerDid: nil, now: now)
    #expect(viewer.items.map(\.itemID) == ["allowed"])
    #expect(anonymous.items.map(\.itemID) == ["muted-0"])
    #expect(viewer.cursor == nil && anonymous.cursor == nil)
    #expect(await transport.targets == Array(repeating:
      "/internal/wire/v1/feed?fallbackLimit=5000&language=en&limit=100&startOrdinal=0", count: 2))

    let shell = WireEditionAssembler.assemble(generationID: page.generationID, generatedAt: now,
      language: "en", source: .simplifiedFallback, degraded: true, rankedItems: Array(rows.prefix(50).map(\.item)))
    let editionResponse = try encodedResponse(WireCorpusEdition(edition: shell,
      sourceActorKeysByItemID: [:], fallbackRows: rows))
    let editionStore = try RemoteWireFeedStore(transport: StubWireCorpusTransport(responses: [editionResponse, editionResponse]),
      cursorSecret: cursorSecret, mode: .visible, moderationCache: cache)
    let edition = try await editionStore.getEdition(language: "en", region: nil, viewerDid: "did:plc:viewer", now: now)
    #expect(edition.leadStories.map(\.itemID) == ["allowed"])
    #expect(edition.cursor == nil)
    let publicEdition = try await editionStore.getEdition(language: "en", region: nil, viewerDid: nil, now: now)
    #expect(publicEdition.leadStories.first?.itemID == "muted-0")
    let publicJSON = String(decoding: try JSONEncoder().encode(WireEditionResponse(edition: publicEdition)), as: UTF8.self)
    #expect(!publicJSON.contains("fallbackRows"))
    #expect(!publicJSON.contains("sourceActorKeysByItemID"))
  }

  @Test("legacy fallback compatibility is anonymous only and ranked cursors stay narrow")
  func fallbackRolloutBoundaries() async throws {
    let cache = WireViewerModerationCache()
    await cache.store(WireViewerModerationSnapshot(blockedDIDs: [], mutedDIDs: [], mutedWords: [], fetchedAt: now),
      viewerDID: "did:plc:viewer")
    let rejection = WireCorpusTransportResponse(statusCode: 400, contractVersion: 3, body: Data())
    let fallback = WireCorpusPage(generationID: "fallback-1", generatedAt: now, language: "en",
      source: .simplifiedFallback, degraded: true, rows: [], exhausted: true)
    let transport = StubWireCorpusTransport(responses: [rejection, try encodedResponse(fallback), rejection])
    let store = try RemoteWireFeedStore(transport: transport, cursorSecret: cursorSecret, mode: .visible, moderationCache: cache)
    _ = try await store.getFeed(cursor: nil, limit: 1, language: "en", viewerDid: nil, now: now)
    await #expect(throws: WireServingError.unavailable) {
      try await store.getFeed(cursor: nil, limit: 1, language: "en", viewerDid: "did:plc:viewer", now: now)
    }
    #expect(await transport.targets == [
      "/internal/wire/v1/feed?fallbackLimit=5000&language=en&limit=100&startOrdinal=0",
      "/internal/wire/v1/feed?language=en&limit=100&startOrdinal=0",
      "/internal/wire/v1/feed?fallbackLimit=5000&language=en&limit=100&startOrdinal=0"])
    let edition = WireEditionAssembler.assemble(generationID: "fallback-1", generatedAt: now,
      language: "en", source: .simplifiedFallback, degraded: true, rankedItems: [])
    let editionStore = try RemoteWireFeedStore(transport: StubWireCorpusTransport(responses: [
      try encodedResponse(WireCorpusEdition(edition: edition, sourceActorKeysByItemID: [:]))]),
      cursorSecret: cursorSecret, mode: .visible, moderationCache: cache)
    await #expect(throws: WireServingError.unavailable) {
      try await editionStore.getEdition(language: "en", region: nil, viewerDid: "did:plc:viewer", now: now)
    }
    let generation = UUID().uuidString.lowercased()
    let cursor = try WireCursorCodec(secret: cursorSecret).encode(
      WireCursor(generationID: generation, language: "en", nextOrdinal: 500))
    let rankedTransport = StubWireCorpusTransport(responses: [try encodedResponse(WireCorpusPage(
      generationID: generation, generatedAt: now, language: "en", source: .ranked,
      degraded: false, rows: [], exhausted: true))])
    let rankedStore = try RemoteWireFeedStore(transport: rankedTransport,
      cursorSecret: cursorSecret, mode: .visible, moderationCache: cache)
    _ = try await rankedStore.getFeed(cursor: cursor, limit: 1, language: "en", viewerDid: nil, now: now)
    #expect(await rankedTransport.targets == [
      "/internal/wire/v1/feed?generationId=\(generation)&language=en&limit=100&startOrdinal=500"])
  }

  @Test("fallback response still fails closed above the eight MiB body cap")
  func oversizedFallbackBody() async throws {
    let page = WireCorpusPage(generationID: "fallback-1", generatedAt: now, language: "en",
      source: .simplifiedFallback, degraded: true, rows: [], exhausted: true)
    let encoded = try encodedResponse(page)
    // Valid trailing JSON whitespace ensures this is a size failure, not invalid JSON.
    let body = encoded.body + Data(repeating: 0x20, count: 8 * 1024 * 1024)
    let store = try RemoteWireFeedStore(transport: StubWireCorpusTransport(responses: [
      WireCorpusTransportResponse(statusCode: 200, contractVersion: 3, body: body)]),
      cursorSecret: cursorSecret, mode: .visible, moderationCache: WireViewerModerationCache())
    await #expect(throws: WireServingError.unavailable) {
      try await store.getFeed(cursor: nil, limit: 1, language: "en", viewerDid: nil, now: now)
    }
  }

  @Test("ranked batches continue past muted rows and preserve delivery cursors and partial final pages")
  func rankedBatchModerationAndCursors() async throws {
    let generation = UUID().uuidString.lowercased()
    let cache = WireViewerModerationCache()
    await cache.store(WireViewerModerationSnapshot(blockedDIDs: [], mutedDIDs: [],
      mutedWords: ["hidden"], fetchedAt: now), viewerDID: "did:plc:viewer")
    func page(_ range: Range<Int>, exhausted: Bool) throws -> WireCorpusTransportResponse {
      try encodedResponse(WireCorpusPage(generationID: generation, generatedAt: now,
        language: "en", source: .ranked, degraded: false,
        rows: range.map { WireCorpusRow(ordinal: $0,
          item: item(id: "row-\($0)", title: $0 < 600 ? "Hidden" : "Allowed", actor: nil),
          sourceActorKey: nil) }, exhausted: exhausted))
    }
    let transport = StubWireCorpusTransport(responses: [
      try page(0..<100, exhausted: false), try page(100..<600, exhausted: false),
      try page(600..<651, exhausted: true), try page(650..<651, exhausted: true)])
    let store = try RemoteWireFeedStore(transport: transport, cursorSecret: cursorSecret,
      mode: .visible, moderationCache: cache)
    let first = try await store.getFeed(cursor: nil, limit: 50, language: "en",
      viewerDid: "did:plc:viewer", now: now)
    #expect(first.items.map(\.itemID) == (600..<650).map { "row-\($0)" })
    let cursor = try #require(first.cursor)
    #expect(try WireCursorCodec(secret: cursorSecret).decode(cursor).nextOrdinal == 650)
    let final = try await store.getFeed(cursor: cursor, limit: 50, language: "en",
      viewerDid: "did:plc:viewer", now: now)
    #expect(final.items.map(\.itemID) == ["row-650"])
    #expect(final.cursor == nil)
    #expect(await transport.targets == [
      "/internal/wire/v1/feed?fallbackLimit=5000&language=en&limit=100&startOrdinal=0",
      "/internal/wire/v1/feed?generationId=\(generation)&language=en&limit=500&startOrdinal=100",
      "/internal/wire/v1/feed?generationId=\(generation)&language=en&limit=500&startOrdinal=600",
      "/internal/wire/v1/feed?generationId=\(generation)&language=en&limit=100&startOrdinal=650"])
  }

  @Test("ranked moderation stops at five thousand scanned rows and returns a continuation")
  func rankedBatchScanBudget() async throws {
    let generation = UUID().uuidString.lowercased()
    let cache = WireViewerModerationCache()
    await cache.store(WireViewerModerationSnapshot(blockedDIDs: [], mutedDIDs: [],
      mutedWords: ["hidden"], fetchedAt: now), viewerDID: "did:plc:viewer")
    let ranges = [0..<100] + stride(from: 100, to: 5000, by: 500).map { $0..<min($0 + 500, 5000) }
    let responses = try ranges.map { range in
      try encodedResponse(WireCorpusPage(generationID: generation, generatedAt: now,
        language: "en", source: .ranked, degraded: false,
        rows: range.map { WireCorpusRow(ordinal: $0,
          item: item(id: "row-\($0)", title: "Hidden", actor: nil), sourceActorKey: nil) },
        exhausted: false))
    }
    let transport = StubWireCorpusTransport(responses: responses)
    let store = try RemoteWireFeedStore(transport: transport, cursorSecret: cursorSecret,
      mode: .visible, moderationCache: cache)
    let page = try await store.getFeed(cursor: nil, limit: 50, language: "en",
      viewerDid: "did:plc:viewer", now: now)
    #expect(page.items.isEmpty)
    let cursor = try #require(page.cursor)
    #expect(try WireCursorCodec(secret: cursorSecret).decode(cursor).nextOrdinal == 5000)
    let targets = await transport.targets
    #expect(targets.count == 11)
    #expect(targets.first?.contains("limit=100&startOrdinal=0") == true)
    #expect(targets[1].contains("limit=500&startOrdinal=100"))
    #expect(targets.last?.contains("limit=400&startOrdinal=4600") == true)
  }

  private func item(id: String, title: String, actor: String?) -> WireFeedItem {
    WireFeedItem(
      itemID: id,
      canonicalURL: "https://example.com/\(id)",
      representativeURI: actor.map { "at://\($0)/app.bsky.feed.post/one" },
      title: title,
      summary: nil,
      publishedAt: now,
      thumbnailURL: nil,
      source: WireItemSource(name: "Example", domain: "example.com", publication: nil, author: nil),
      reasons: [],
      provenance: [.standardSite]
    )
  }

  private func encodedResponse<Value: Encodable>(
    _ value: Value,
    contractVersion: Int = 2
  ) throws -> WireCorpusTransportResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return WireCorpusTransportResponse(
      statusCode: 200,
      contractVersion: contractVersion,
      body: try encoder.encode(value)
    )
  }
}

private enum StubError: Error { case unavailable }

private actor StubWireCorpusTransport: WireCorpusTransport {
  private var responses: [WireCorpusTransportResponse]
  private let error: Error?
  private(set) var targets: [String] = []

  init(responses: [WireCorpusTransportResponse] = [], error: Error? = nil) {
    self.responses = responses
    self.error = error
  }

  func get(target: String) async throws -> WireCorpusTransportResponse {
    targets.append(target)
    if let error { throw error }
    guard !responses.isEmpty else { throw StubError.unavailable }
    return responses.removeFirst()
  }
}
