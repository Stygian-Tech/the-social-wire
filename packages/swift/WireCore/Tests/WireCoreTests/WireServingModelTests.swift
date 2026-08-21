import Foundation
import Testing
@testable import WireCore

@Suite("The Wire serving models")
struct WireServingModelTests {
  @Test("uses exact lexicon keys and presentation caps")
  func itemContract() throws {
    let item = WireFeedItem(
      itemID: "wire:item",
      canonicalURL: "https://example.com/story",
      representativeURI: nil,
      title: "Story",
      summary: nil,
      publishedAt: nil,
      thumbnailURL: nil,
      source: .init(name: "Example", domain: "example.com"),
      reasons: [.breakingStory, .widelyDiscussed, .resurfacing],
      provenance: Array(repeating: .like, count: 9)
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
    )
    #expect(object["itemId"] as? String == "wire:item")
    #expect(object["canonicalUrl"] as? String == "https://example.com/story")
    #expect(object["score"] == nil)
    #expect(object["rank"] == nil)
    #expect(item.reasons.count == 2)
    #expect(item.provenance.count == 8)
  }

  @Test("catalog is the singleton lexicon shape and exact product copy")
  func catalogContract() throws {
    let catalog = WireFeedCatalog(
      enabled: true,
      available: true,
      supportedLanguages: ["en"],
      latestGenerationID: "generation"
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any]
    )
    #expect(object["feeds"] == nil)
    #expect(object["latestGenerationId"] as? String == "generation")
    #expect(catalog.title == "The Wire")
    #expect(catalog.subtitle == "Important stories across the social web")
  }
}
