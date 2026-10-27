import Feeds
import Testing

struct ProfileBioFacetDetectorTests {
    @Test
    func detectsMentionHashtagAndCashtagUsingUTF8Offsets() {
        let text = "Hello 👋 @alice.example — #Swift and $AAPL"

        let facets = ProfileBioFacetDetector.facets(in: text)

        #expect(facets.count == 3)
        #expect(substring(for: facets[0], in: text) == "@alice.example")
        #expect(facets[0].features == [.mention(did: "alice.example")])
        #expect(substring(for: facets[1], in: text) == "#Swift")
        #expect(facets[1].features == [.tag("Swift")])
        #expect(substring(for: facets[2], in: text) == "$AAPL")
        #expect(facets[2].features == [.tag("AAPL")])
    }

    @Test
    func ignoresFacetMarkersInsideWords() {
        #expect(ProfileBioFacetDetector.facets(in: "email@example.com C#").isEmpty)
    }

    @Test
    func detectsLinksUsingUTF8Offsets() throws {
        let text = "Work 👩🏽‍💻 https://example.com/about"

        let facet = try #require(ProfileBioFacetDetector.facets(in: text).first)

        #expect(substring(for: facet, in: text) == "https://example.com/about")
        #expect(facet.features == [.link(uri: "https://example.com/about")])
    }

    private func substring(for facet: TimelineFacet, in text: String) -> String? {
        guard let start = text.utf8.index(text.utf8.startIndex, offsetBy: facet.byteStart, limitedBy: text.utf8.endIndex),
              let end = text.utf8.index(text.utf8.startIndex, offsetBy: facet.byteEnd, limitedBy: text.utf8.endIndex),
              let lowerBound = String.Index(start, within: text),
              let upperBound = String.Index(end, within: text) else { return nil }
        return String(text[lowerBound..<upperBound])
    }
}
