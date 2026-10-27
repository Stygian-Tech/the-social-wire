import ATProtoCore
import Foundation
import Testing
@testable import Feeds

@Suite("Timeline Video")
struct TimelineVideoTests {
    private let videoEmbed = #"{"$type":"app.bsky.embed.video#view","cid":"bafyvideo","playlist":"https://video.example/playlist.m3u8","thumbnail":"https://video.example/thumb.jpg","alt":"A bird","aspectRatio":{"width":1080,"height":1920}}"#

    @Test("Direct and record-with-media videos survive timeline decoding", arguments: [false, true])
    func decodesVideo(recordWithMedia: Bool) async throws {
        let embed = recordWithMedia ? #"{"$type":"app.bsky.embed.recordWithMedia#view","media":\#(videoEmbed)}"# : videoEmbed
        let data = Data(#"{"feed":[{"post":\#(post(embed: embed))}]}"#.utf8)
        let source = ATProtoTimelineSource { _ in data }
        let page = try await source.timeline(cursor: nil)
        let video = try #require(page.posts.first?.video)
        #expect(video.playlistURL.absoluteString == "https://video.example/playlist.m3u8")
        #expect(video.altText == "A bird")
        #expect(video.width == 1080)
        #expect(video.aspectRatio == 0.75)
        #expect(page.posts[0].replacingExternalEmbed(nil).video == video)
        #expect(page.posts[0].replacingQuote(nil).video == video)
    }

    @Test("Thread and quote videos are decoded")
    func threadAndQuote() async throws {
        let quote = #"{"$type":"app.bsky.embed.record#view","record":{"$type":"app.bsky.embed.record#viewRecord","uri":"at://did:plc:bob/app.bsky.feed.post/quoted","cid":"bafyquote","author":{"did":"did:plc:bob","handle":"bob.test"},"value":{"text":"Quoted","createdAt":"2026-10-01T00:00:00Z"},"embeds":[\#(videoEmbed)]}}"#
        let combined = #"{"$type":"app.bsky.embed.recordWithMedia#view","record":\#(quote),"media":\#(videoEmbed)}"#
        let data = Data(#"{"thread":{"$type":"app.bsky.feed.defs#threadViewPost","post":\#(post(embed: combined))}}"#.utf8)
        let source = ATProtoPostThreadSource { _ in data }
        let thread = try await source.thread(uri: try ATURI("at://did:plc:alice/app.bsky.feed.post/key"))
        let entry = try #require(thread.entries.first)
        #expect(entry.post.video != nil)
        let decodedQuote = try #require(entry.post.quote)
        #expect(decodedQuote.video?.altText == "A bird")
        #expect(decodedQuote.replacingExternalEmbed(nil).video == decodedQuote.video)
    }

    @Test("Unsafe playlists do not become playable videos")
    func rejectsUnsafePlaylist() async throws {
        let unsafe = videoEmbed.replacingOccurrences(of: "https://video.example/playlist.m3u8", with: "file:///private/file")
        let data = Data(#"{"feed":[{"post":\#(post(embed: unsafe))}]}"#.utf8)
        let page = try await ATProtoTimelineSource { _ in data }.timeline(cursor: nil)
        #expect(page.posts.first?.video == nil)
    }

    private func post(embed: String) -> String {
        #"{"uri":"at://did:plc:alice/app.bsky.feed.post/key","cid":"bafypost","author":{"did":"did:plc:alice","handle":"alice.test"},"record":{"text":"Video","createdAt":"2026-10-01T00:00:00Z"},"indexedAt":"2026-10-01T00:00:00Z","embed":\#(embed)}"#
    }
}
