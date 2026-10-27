import ATProtoCore
import Foundation
import Testing
@testable import Feeds

struct NativeGIFSourceTests {
    @Test(arguments: [false, true])
    func recoversOriginalGIFWithoutChangingCDNIdentity(thread: Bool) async throws {
        let post = try await decodePost(
            rawEmbed: imageRecord(["image/jpeg", "image/gif"]),
            viewEmbed: ["images": [imageView(0), imageView(1)]],
            thread: thread
        )
        #expect(post.images.count == 2)
        #expect(post.images[0].originalGIFDID == nil)
        #expect(post.images[0].originalGIFCID == nil)
        #expect(post.images[1].originalGIFDID == "did:plc:alice")
        #expect(post.images[1].originalGIFCID == "bafygif1")
        #expect(post.images[1].id.absoluteString == "https://cdn.test/full1.jpeg")
        #expect(post.images[1].thumbnailURL.absoluteString == "https://cdn.test/thumb1.jpeg")
        #expect(post.images[1].altText == "Image 1")
        #expect(post.images[1].width == 640)
        #expect(post.images[1].height == 360)
    }

    @Test(arguments: [false, true])
    func recoversGIFInRecordWithMedia(thread: Bool) async throws {
        let post = try await decodePost(
            rawEmbed: ["$type": "app.bsky.embed.recordWithMedia", "media": imageRecord(["image/gif"])],
            viewEmbed: ["media": ["images": [imageView(0)]]],
            thread: thread
        )
        #expect(post.images.first?.originalGIFCID == "bafygif0")
    }

    @Test(arguments: [false, true])
    func recoversGIFInGallery(thread: Bool) async throws {
        let post = try await decodePost(
            rawEmbed: ["$type": "app.bsky.embed.gallery", "items": [blobImage("image/gif", index: 0)]],
            viewEmbed: ["items": [[
                "thumbnail": "https://cdn.test/thumb0.jpeg",
                "fullsize": "https://cdn.test/full0.jpeg",
                "alt": "Gallery GIF",
            ]]],
            thread: thread
        )
        #expect(post.images.first?.originalGIFCID == "bafygif0")
    }

    @Test(arguments: [false, true])
    func quotedGIFUsesQuotedAuthorsDID(thread: Bool) async throws {
        let quotedRecord: [String: Any] = [
            "uri": "at://did:plc:bob/app.bsky.feed.post/quote",
            "cid": "bafyquote",
            "author": ["did": "did:plc:bob", "handle": "bob.test"],
            "value": [
                "text": "GIF quote", "createdAt": "2026-09-21T12:00:00Z",
                "embed": imageRecord(["image/gif"]),
            ],
            "embeds": [["images": [imageView(0)]]],
        ]
        let post = try await decodePost(
            rawEmbed: ["$type": "app.bsky.embed.record"],
            viewEmbed: ["record": ["record": quotedRecord]],
            thread: thread
        )
        #expect(post.quote?.images.first?.originalGIFDID == "did:plc:bob")
        #expect(post.quote?.images.first?.originalGIFCID == "bafygif0")
    }

    @Test(arguments: [false, true])
    func malformedOptionalBlobDoesNotPreventPostDecoding(thread: Bool) async throws {
        let post = try await decodePost(
            rawEmbed: ["$type": "app.bsky.embed.images", "images": [
                ["image": ["mimeType": "image/gif", "ref": ["$link": 42]]],
            ]],
            viewEmbed: ["images": [imageView(0)]],
            thread: thread
        )
        #expect(post.images.count == 1)
        #expect(post.images.first?.originalGIFCID == nil)
    }

    @Test(arguments: [false, true])
    func mismatchedCountsDoNotAssociateGIFWithWrongImage(thread: Bool) async throws {
        let post = try await decodePost(
            rawEmbed: imageRecord(["image/gif", "image/jpeg"]),
            viewEmbed: ["images": [imageView(0)]],
            thread: thread
        )
        #expect(post.images.first?.originalGIFCID == nil)
    }

    private func blobImage(_ mimeType: String, index: Int) -> [String: Any] {
        ["image": ["$type": "blob", "mimeType": mimeType, "ref": ["$link": "bafygif\(index)"], "size": 100]]
    }

    private func imageRecord(_ mimeTypes: [String]) -> [String: Any] {
        ["$type": "app.bsky.embed.images", "images": mimeTypes.enumerated().map { blobImage($1, index: $0) }]
    }

    private func imageView(_ index: Int) -> [String: Any] {
        [
            "thumb": "https://cdn.test/thumb\(index).jpeg",
            "fullsize": "https://cdn.test/full\(index).jpeg",
            "alt": "Image \(index)",
            "aspectRatio": ["width": 640, "height": 360],
        ]
    }

    private func decodePost(
        rawEmbed: [String: Any], viewEmbed: [String: Any], thread: Bool
    ) async throws -> TimelinePost {
        let uri = "at://did:plc:alice/app.bsky.feed.post/gif"
        let post: [String: Any] = [
            "uri": uri, "cid": "bafypost",
            "author": ["did": "did:plc:alice", "handle": "alice.test"],
            "record": ["text": "GIF", "createdAt": "2026-09-21T12:00:00Z", "embed": rawEmbed],
            "indexedAt": "2026-09-21T12:00:01Z", "embed": viewEmbed,
        ]
        if thread {
            let data = try JSONSerialization.data(withJSONObject: ["thread": ["post": post]])
            let source = ATProtoPostThreadSource { _ in data }
            let result = try await source.thread(uri: ATURI(uri))
            return try #require(result.entries.first?.post)
        }
        let data = try JSONSerialization.data(withJSONObject: ["feed": [["post": post]]])
        let source = ATProtoTimelineSource { _ in data }
        let result = try await source.timeline(cursor: nil)
        return try #require(result.posts.first)
    }
}
