import Foundation
import Testing
@testable import WireCore

@Suite("Wire corpus transport bounds")
struct WireCorpusTransportBoundsTests {
  @Test("fallback alone can carry the bounded candidate set before viewer moderation")
  func sourceSpecificBounds() throws {
    let item = WireFeedItem(itemID: "one", canonicalURL: "https://example.com/one",
      representativeURI: nil, title: "One", summary: nil, publishedAt: nil,
      thumbnailURL: nil, source: WireItemSource(name: "Example", domain: "example.com",
        publication: nil, author: nil), reasons: [], provenance: [])
    let rows = (0..<5001).map { WireCorpusRow(ordinal: $0, item: item, sourceActorKey: nil) }
    for source in [WirePageSource.ranked, .staleGeneration, .simplifiedFallback] {
      let page = WireCorpusPage(generationID: "generation", generatedAt: Date(timeIntervalSince1970: 0),
        language: "en", source: source, degraded: false, rows: rows, exhausted: true)
      #expect(page.rows.count == (source == .simplifiedFallback ? 5000 : 500))
      #expect(try JSONDecoder().decode(WireCorpusPage.self, from: JSONEncoder().encode(page)) == page)
    }
  }
}
