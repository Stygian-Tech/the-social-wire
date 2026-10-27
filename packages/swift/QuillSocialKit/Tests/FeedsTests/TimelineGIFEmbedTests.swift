import Foundation
import Testing
@testable import Feeds

struct TimelineGIFEmbedTests {
    @Test func animatedSourceWinsOverStaticThumbnail() throws {
        let source = try #require(URL(string: "https://static.klipy.com/ii/example.gif?ww=240&hh=400"))
        let embed = TimelineExternalEmbed(uri: source, title: "GIF", description: "", thumbnailURL: URL(string: "https://cdn.bsky.app/thumb.jpeg"))
        #expect(embed.animatedGIFURL == source)
        #expect(embed.gifAspectRatio == 0.6)
    }

    @Test func providerWebpageIsNotMistakenForAnimatedMedia() throws {
        let embed = TimelineExternalEmbed(uri: try #require(URL(string: "https://giphy.com/gifs/example")), title: "", description: "", thumbnailURL: URL(string: "https://cdn.bsky.app/thumb.jpeg"))
        #expect(embed.animatedGIFURL == nil)
        #expect(embed.gifAspectRatio == nil)
    }

    @Test func directGIFDoesNotRequireThumbnail() throws {
        let source = try #require(URL(string: "https://media.tenor.com/id/example.gif"))
        let embed = TimelineExternalEmbed(uri: source, title: "", description: "")
        #expect(embed.animatedGIFURL == source)
        #expect(embed.gifAspectRatio == nil)
    }

    @Test(arguments: ["ww=nan&hh=20", "ww=200&hh=0", "ww=-1&hh=20"])
    func invalidDimensionsAreIgnored(query: String) throws {
        let embed = TimelineExternalEmbed(uri: try #require(URL(string: "https://example.com/a.gif?\(query)")), title: "", description: "")
        #expect(embed.gifAspectRatio == nil)
    }
}
