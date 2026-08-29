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
      "/internal/wire/v1/edition?language=en&region=outside-us",
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
      "/internal/wire/v1/edition?language=en&region=outside-us",
      "/internal/wire/v1/edition?language=en",
    ])
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

  private func encodedResponse<Value: Encodable>(_ value: Value) throws -> WireCorpusTransportResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return WireCorpusTransportResponse(
      statusCode: 200,
      contractVersion: 2,
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
