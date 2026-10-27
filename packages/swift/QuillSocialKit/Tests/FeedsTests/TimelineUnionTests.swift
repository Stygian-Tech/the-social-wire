import Foundation
import Testing
@testable import Feeds

@Suite("Timeline Lexicon Unions")
struct TimelineUnionTests {
    @Test("Unavailable reply parents do not discard a valid feed page", arguments: ["notFoundPost", "blockedPost"])
    func unavailableReplyParent(kind: String) async throws {
        var parent: [String: Any] = ["$type": "app.bsky.feed.defs#\(kind)", "uri": "at://did:plc:parent/app.bsky.feed.post/one"]
        if kind == "blockedPost" { parent["author"] = ["did": "did:plc:parent"] }
        let reply: [String: Any] = ["parent": parent]
        let page = try await load(extra: ["reply": reply])
        #expect(page.posts.count == 1)
        #expect(page.posts[0].text == "Still Visible")
        #expect(page.posts[0].replyingTo == nil)
        #expect(page.cursor == "next")
    }

    @Test("Pinned feed reasons do not require a reposting author")
    func pinReason() async throws {
        let page = try await load(extra: ["reason": ["$type": "app.bsky.feed.defs#reasonPin"]])
        #expect(page.posts.count == 1)
        #expect(page.posts[0].repostedBy == nil)
    }

    @Test("Quoted feed and list records do not decode as posts", arguments: ["app.bsky.feed.generator", "app.bsky.graph.list"])
    func foreignQuotedRecord(collection: String) async throws {
        let embed: [String: Any] = ["$type": "app.bsky.embed.record#view", "record": [
            "$type": "app.bsky.embed.record#viewRecord", "uri": "at://did:plc:alice/\(collection)/one",
            "cid": "bafyforeign", "author": ["did": "did:plc:alice", "handle": "alice.test"],
            "value": ["$type": collection, "name": "A Feed Or List"]
        ]]
        let page = try await load(postExtra: ["embed": embed])
        #expect(page.posts.count == 1)
        #expect(page.posts[0].quote == nil)
    }

    @Test("Malformed actual post records remain decoding failures")
    func malformedQuotedPost() async throws {
        let embed: [String: Any] = ["record": ["value": ["$type": "app.bsky.feed.post", "createdAt": "2026-10-26T00:00:00Z"]]]
        await #expect(throws: DecodingError.self) {
            _ = try await load(postExtra: ["embed": embed])
        }
    }

    private func load(extra: [String: Any] = [:], postExtra: [String: Any] = [:]) async throws -> TimelinePage {
        var post: [String: Any] = [
            "uri": "at://did:plc:alice/app.bsky.feed.post/one", "cid": "bafyone",
            "author": ["did": "did:plc:alice", "handle": "alice.test"],
            "record": ["$type": "app.bsky.feed.post", "text": "Still Visible", "createdAt": "2026-10-26T00:00:00Z"],
            "indexedAt": "2026-10-26T00:00:00Z"
        ]
        post.merge(postExtra) { _, new in new }
        var row = extra
        row["post"] = post
        let data = try JSONSerialization.data(withJSONObject: ["feed": [row], "cursor": "next"])
        return try await ATProtoTimelineSource { _ in data }.timeline(cursor: nil)
    }
}
