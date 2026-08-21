import Testing
@testable import WireCore

@Suite("The Wire canonicalizer")
struct WireCanonicalizerTests {
  @Test("normalizes transport, host, port, tracking, query order, and fragments")
  func normalizesKnownNoise() throws {
    let identity = try #require(
      WireCanonicalizer.canonicalize(
        "http://EXAMPLE.com:80/story/?utm_source=newsletter&b=2&a=1#comments"
      )
    )
    #expect(identity.canonicalURL == "https://example.com/story?a=1&b=2")
    #expect(identity.canonicalKey.hasPrefix("url:"))
    #expect(identity.canonicalKey.count == 68)
  }

  @Test("preserves semantic query parameters")
  func preservesSemanticParameters() throws {
    let first = try #require(WireCanonicalizer.canonicalize("https://example.com/search?q=swift"))
    let second = try #require(WireCanonicalizer.canonicalize("https://example.com/search?q=rust"))
    #expect(first != second)
  }

  @Test("aliases tracking-only variants")
  func aliasesTrackingVariants() throws {
    let first = try #require(WireCanonicalizer.canonicalize("https://example.com/a?utm_medium=social"))
    let second = try #require(WireCanonicalizer.canonicalize("https://EXAMPLE.com/a#top"))
    #expect(first == second)
  }

  @Test(arguments: ["ftp://example.com/a", "not a url", "https://user:pass@example.com/a"])
  func rejectsUnsupportedURLs(_ value: String) {
    #expect(WireCanonicalizer.canonicalize(value) == nil)
  }
}
