import Foundation
import Testing
import WireCore

@testable import AppView

@Suite("Your Circle remote candidate store")
struct RemoteCircleCandidateFetcherTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("chunks opaque actors and globally selects participant breadth")
  func chunksAndSelectsGlobally() async throws {
    let hashes = (0...WireCorpusCandidateRequest.maximumActorHashesPerRequest).map { index in
      "h1:" + String(format: "%064x", index)
    }
    let first = story(id: "narrow", actorHashes: [hashes[0]], occurredAt: now)
    let broad = story(
      id: "broad",
      actorHashes: [hashes[1], hashes.last!],
      occurredAt: now.addingTimeInterval(-60)
    )
    let transport = CircleCandidateTransport(responses: [
      try response(stories: [first]),
      try response(stories: [broad]),
    ])
    let fetcher = RemoteCircleCandidateFetcher(transport: transport)

    let result = try await fetcher.candidates(
      actorHashes: hashes,
      language: "en",
      since: now.addingTimeInterval(-3_600),
      limit: 1,
      now: now
    )

    #expect(result.stories.map(\.item.itemID) == ["broad"])
    #expect(result.exhausted == false)
    let submitted = await transport.requests()
    #expect(submitted.count == 2)
    #expect(submitted[0].actorHashes.count == 5_000)
    #expect(submitted[1].actorHashes.count == 1)
    #expect(submitted.flatMap(\.actorHashes).allSatisfy { $0.hasPrefix("h1:") })
  }

  @Test("merges facts and topics for the same story across chunks")
  func mergesDuplicateStoryFacts() async throws {
    let firstHash = "h1:" + String(repeating: "a", count: 64)
    let secondHash = "h1:" + String(repeating: "b", count: 64)
    let first = story(
      id: "same",
      actorHashes: [firstHash],
      occurredAt: now,
      topics: ["technology"]
    )
    let second = story(
      id: "same",
      actorHashes: [secondHash],
      occurredAt: now.addingTimeInterval(-60),
      topics: ["science"]
    )
    let transport = CircleCandidateTransport(responses: [
      try response(stories: [first]),
      try response(stories: [second]),
    ])
    let fetcher = RemoteCircleCandidateFetcher(transport: transport)
    let actorHashes =
      Array(
        repeating: firstHash,
        count: WireCorpusCandidateRequest.maximumActorHashesPerRequest
      ) + [secondHash]

    let result = try await fetcher.candidates(
      actorHashes: actorHashes,
      language: "en",
      since: now.addingTimeInterval(-3_600),
      limit: 10,
      now: now
    )

    let merged = try #require(result.stories.first)
    #expect(merged.facts.map(\.actorHash) == [firstHash, secondHash])
    #expect(merged.topicKeys == ["science", "technology"])
    #expect(result.generatedAt == now.addingTimeInterval(-120))
  }

  private func story(
    id: String,
    actorHashes: [String],
    occurredAt: Date,
    topics: [String] = []
  ) -> WireCorpusCandidateStory {
    WireCorpusCandidateStory(
      item: WireFeedItem(
        itemID: id,
        canonicalURL: "https://example.com/\(id)",
        representativeURI: "at://did:plc:author/app.bsky.feed.post/\(id)",
        title: id,
        summary: "Summary",
        publishedAt: occurredAt,
        thumbnailURL: nil,
        source: WireItemSource(name: "Example", domain: "example.com"),
        reasons: [],
        provenance: [.standardSite]
      ),
      topicKeys: topics,
      facts: actorHashes.enumerated().map { index, hash in
        WireCorpusSignalFact(
          actorHash: hash,
          kind: .share,
          sourceCollection: "app.bsky.feed.repost",
          sourceAction: "repost",
          sourceURI: "at://did:plc:actor/app.bsky.feed.repost/\(id)-\(index)",
          occurredAt: occurredAt
        )
      }
    )
  }

  private func response(
    stories: [WireCorpusCandidateStory]
  ) throws -> WireCorpusTransportResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return WireCorpusTransportResponse(
      statusCode: 200,
      contractVersion: 3,
      body: try encoder.encode(
        WireCorpusCandidateResponse(
          generationID: "generation-1",
          generatedAt: now.addingTimeInterval(-120),
          language: "en",
          stories: stories,
          exhausted: true
        )
      )
    )
  }
}

private actor CircleCandidateTransport: WireCorpusTransport {
  private var responses: [WireCorpusTransportResponse]
  private var submitted: [WireCorpusCandidateRequest] = []

  init(responses: [WireCorpusTransportResponse]) {
    self.responses = responses
  }

  func get(target: String) async throws -> WireCorpusTransportResponse {
    throw WireServingError.corpusContractMismatch
  }

  func post(target: String, body: Data) async throws -> WireCorpusTransportResponse {
    #expect(target == "/internal/wire/v1/circle-candidates")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    submitted.append(try decoder.decode(WireCorpusCandidateRequest.self, from: body))
    return responses.removeFirst()
  }

  func requests() -> [WireCorpusCandidateRequest] { submitted }
}
