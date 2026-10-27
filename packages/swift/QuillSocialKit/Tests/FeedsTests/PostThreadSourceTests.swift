import ATProtoCore
import Foundation
import Testing
@testable import Feeds

@Suite("Post Thread Source")
struct PostThreadSourceTests {
    @Test("Decodes parent context, nested replies, and images")
    func decodesThread() async throws {
        let data = Data("""
        {
          "thread": {
            "$type": "app.bsky.feed.defs#threadViewPost",
            "post": \(post(uri: "at://did:plc:alice/app.bsky.feed.post/focus", text: "Focused", image: true)),
            "parent": {
              "$type": "app.bsky.feed.defs#threadViewPost",
              "post": \(post(uri: "at://did:plc:alice/app.bsky.feed.post/parent", text: "Parent"))
            },
            "replies": [{
              "$type": "app.bsky.feed.defs#threadViewPost",
              "post": \(post(uri: "at://did:plc:bob/app.bsky.feed.post/reply", text: "Reply")),
              "replies": [{
                "$type": "app.bsky.feed.defs#threadViewPost",
                "post": \(post(uri: "at://did:plc:carol/app.bsky.feed.post/nested", text: "Nested"))
              }]
            }]
          }
        }
        """.utf8)
        let source = ATProtoPostThreadSource { parameters in
            #expect(parameters["uri"] == "at://did:plc:alice/app.bsky.feed.post/focus")
            #expect(parameters["depth"] == "6")
            return data
        }

        let thread = try await source.thread(
            uri: try ATURI("at://did:plc:alice/app.bsky.feed.post/focus")
        )

        #expect(thread.entries.map(\.post.text) == ["Parent", "Focused", "Reply", "Nested"])
        #expect(thread.entries.map(\.depth) == [-1, 0, 1, 2])
        #expect(thread.entries[1].isFocused)
        #expect(thread.entries[1].replyingTo?.handle == "alice.test")
        #expect(thread.entries[2].replyingTo?.handle == "alice.test")
        #expect(thread.entries[1].post.images.first?.altText == "A blue sky")
    }

    @Test("Collapses reply branches after three levels")
    func capsReplyDepth() {
        let author = TimelineAuthor(did: "did:plc:alice", handle: "alice.test")
        let entries = (0...5).map { depth in
            ThreadEntry(
                post: TimelinePost(
                    uri: "at://did:plc:alice/app.bsky.feed.post/\(depth)",
                    cid: "cid-\(depth)",
                    author: author,
                    text: "Depth \(depth)",
                    createdAt: .now
                ),
                depth: depth,
                isFocused: depth == 0,
                replyingTo: depth == 0 ? nil : author
            )
        }
        let thread = PostThread(entries: entries)

        let collapsed = thread.displayItems()
        #expect(collapsed.count == 5)
        #expect(collapsed.last == .showMore(parentID: entries[3].id, hiddenCount: 2))

        let expanded = thread.displayItems(expandedParentIDs: [entries[3].id])
        #expect(expanded.count == 6)
    }

    private func post(uri: String, text: String, image: Bool = false) -> String {
        let embed = image ? """
        ,"embed":{"images":[{"thumb":"https://cdn.test/thumb.jpg","fullsize":"https://cdn.test/full.jpg","alt":"A blue sky","aspectRatio":{"width":1600,"height":900}}]}
        """ : ""
        return """
        {"uri":"\(uri)","cid":"bafy","author":{"did":"did:plc:alice","handle":"alice.test"},"record":{"text":"\(text)","createdAt":"2026-09-21T12:00:00.000Z"},"replyCount":0,"repostCount":0,"likeCount":0,"quoteCount":0,"indexedAt":"2026-09-21T12:00:01.000Z"\(embed)}
        """
    }
}
