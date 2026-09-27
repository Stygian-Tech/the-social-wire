import Foundation
import Testing
import WireCore

@testable import WireWorkerCore

@Suite("The Wire deterministic post links")
struct WirePostLinkExtractorTests {
  // Shapes from every multi-URL post that varied in the captured replay.
  // URLs and text are synthetic; no captured user content is checked in.
  @Test(arguments: [1143, 2409, 2457, 3514, 3612, 4622, 5252, 5698, 8501, 11853])
  func capturedMultiLinkShapesPreferTheirCard(sequence: Int) throws {
    let canonicalURL = "https://article.example/story/\(sequence)"
    let cardURL = canonicalURL + (sequence == 5698 ? "?utm_source=card" : "")
    let facetPosition =
      switch sequence {
      case 1143: 4
      case 3514: 1
      case 4622: 3
      default: 0
      }
    var facets: [[String: Any]] = (0..<facetPosition).map { index in
      [
        "index": ["byteStart": index * 10, "byteEnd": index * 10 + 5],
        "features": [["$type": "app.bsky.richtext.facet#tag", "tag": "topic"]],
      ]
    }
    facets.append(linkFacet("https://facet.example/other/\(sequence)", byteStart: 50))
    if sequence == 3612 {
      facets.append(linkFacet(cardURL, byteStart: 80))
    }
    let card: [String: Any] = [
      "$type": "app.bsky.embed.external",
      "external": ["uri": cardURL, "title": "Card title", "description": "Card summary"],
    ]
    let embed: [String: Any] =
      sequence == 1143
      ? [
        "$type": "app.bsky.embed.recordWithMedia", "media": card,
        "record": ["record": ["uri": "at://did:plc:example/app.bsky.feed.post/quote"]],
      ]
      : card
    let record: [String: Any] = [
      "$type": "app.bsky.feed.post", "text": "Shared article", "embed": embed, "facets": facets,
    ]
    for reverse in [false, true] {
      let variant = try #require(reordered(record, reverse: reverse) as? [String: Any])
      let selected = try #require(WirePostLinkExtractor.externalURL(in: variant))
      #expect(selected == cardURL)
      #expect(WireCanonicalizer.canonicalize(selected)?.canonicalURL == canonicalURL)
      #expect(
        WireEmbeddedCardMetadata.extract(from: variant, canonicalURL: canonicalURL)?.title
          == "Card title")
    }
  }

  @Test func directCardPrecedesMediaAndLegacyURLFollowsURI() {
    let record: [String: Any] = [
      "embed": [
        "external": ["uri": "http://direct.example/story", "url": "https://legacy.example/story"],
        "media": ["external": ["uri": "https://media.example/story"]],
      ],
      "a": ["url": "https://nested.example/story"],
    ]
    #expect(WirePostLinkExtractor.externalURL(in: record) == "http://direct.example/story")
    #expect(
      WirePostLinkExtractor.externalURL(in: [
        "embed": ["external": ["uri": "at://invalid-card", "url": "https://legacy.example/story"]],
        "facets": [linkFacet("https://facet.example/story")],
      ]) == "https://legacy.example/story")
  }

  @Test func fallbackUsesSortedObjectKeysAndPreservesArrayOrder() throws {
    let record: [String: Any] = [
      "z": ["uri": "https://later.example/story"],
      "a": ["url": "https://first.example/story"],
    ]
    for reverse in [false, true] {
      let variant = try #require(reordered(record, reverse: reverse) as? [String: Any])
      #expect(WirePostLinkExtractor.externalURL(in: variant) == "https://first.example/story")
    }
    #expect(
      WirePostLinkExtractor.externalURL(in: [
        "facets": [
          linkFacet("https://array-first.example/story", byteStart: 90),
          linkFacet("https://text-first.example/story", byteStart: 0),
        ]
      ]) == "https://array-first.example/story")
    #expect(
      WirePostLinkExtractor.externalURL(in: [
        "legacy": ["url": "https://url.example/story", "uri": "https://uri.example/story"]
      ]) == "https://uri.example/story")
  }

  @Test(arguments: ["ftp://invalid.example/story", "at://did:plc:example/post", "https:", ""])
  func invalidCardsRetainStructuredFallback(invalid: String) {
    #expect(
      WirePostLinkExtractor.externalURL(in: [
        "embed": ["external": ["uri": invalid]],
        "facets": [linkFacet("https://fallback.example/story")],
      ]) == "https://fallback.example/story")
  }

  @Test func malformedObjectsAndUnstructuredTextDoNotBecomeLinks() {
    #expect(
      WirePostLinkExtractor.externalURL(in: [
        "embed": ["external": ["uri": ["https://array.example/story"]]],
        "facets": NSNull(), "text": "https://text.example/story",
      ]) == nil)
    #expect(
      WirePostLinkExtractor.externalURL(in: [
        "embed": "malformed", "facets": [NSNull(), 7, ["features": ["uri": 4]]],
      ]) == nil)
  }

  @Test func selectionDoesNotBypassExistingDownstreamRejection() throws {
    let social = "https://bsky.app/profile/example.test/post/one"
    let selected = try #require(
      WirePostLinkExtractor.externalURL(in: [
        "embed": ["external": ["uri": social]],
        "facets": [linkFacet("https://article.example/story")],
      ]))
    #expect(selected == social)
    #expect(!WireContentQualityClassifier.targetKind(for: selected).canCreateItem)
    let credentialURL = "https://user:password@example.test/story"
    #expect(
      WirePostLinkExtractor.externalURL(in: [
        "embed": ["external": ["uri": credentialURL]],
        "facets": [linkFacet("https://article.example/story")],
      ]) == credentialURL)
    #expect(WireCanonicalizer.canonicalize(credentialURL) == nil)
  }

  private func linkFacet(_ url: String, byteStart: Int = 0) -> [String: Any] {
    [
      "index": ["byteStart": byteStart, "byteEnd": byteStart + 5],
      "features": [["$type": "app.bsky.richtext.facet#link", "uri": url]],
    ]
  }

  private func reordered(_ value: Any, reverse: Bool) -> Any {
    if let dictionary = value as? [String: Any] {
      let keys = reverse ? dictionary.keys.sorted().reversed().map { $0 } : dictionary.keys.sorted()
      return keys.reduce(into: [String: Any]()) { result, key in
        result[key] = reordered(dictionary[key]!, reverse: reverse)
      }
    }
    if let array = value as? [Any] { return array.map { reordered($0, reverse: reverse) } }
    return value
  }
}
