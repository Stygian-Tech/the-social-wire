import Testing
@testable import WireWorker

@Suite("The Wire embedded card metadata")
struct WireEmbeddedCardMetadataTests {
  @Test("extracts a matching Bluesky external card")
  func extractsCard() throws {
    let record: [String: Any] = [
      "embed": [
        "$type": "app.bsky.embed.external",
        "external": [
          "uri": "https://news.example/story?utm_source=social",
          "title": "Authoritative card title",
          "description": "Card description",
          "thumb": "https://cdn.example/story.jpg",
        ],
      ],
    ]
    let result = try #require(
      WireEmbeddedCardMetadata.extract(from: record, canonicalURL: "https://news.example/story")
    )
    #expect(result.title == "Authoritative card title")
    #expect(result.imageURL == "https://cdn.example/story.jpg")
    #expect(result.source == .embeddedCard)
  }
}
