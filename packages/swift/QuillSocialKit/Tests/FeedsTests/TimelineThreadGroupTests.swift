import ATProtoCore
import Foundation
import Testing
@testable import Feeds

@Suite("Timeline Thread Grouping")
struct TimelineThreadGroupTests {
    @Test("Interleaved conversations stay at their first feed occurrence")
    func groupsInterleavedThreads() {
        let aReply = post("a-reply", root: "a", time: 3)
        let bReply = post("b-reply", root: "b", time: 2)
        let aRoot = post("a", time: 1)
        let bRoot = post("b", time: 1)

        let groups = TimelineThreadGroup.grouping([aReply, bReply, aRoot, bRoot])

        #expect(groups.map(\.id) == ["a", "b"])
        #expect(groups[0].posts == [aRoot, aReply])
        #expect(groups[1].posts == [bRoot, bReply])
        #expect(groups.allSatisfy { !$0.hasMissingRoot })
        #expect(groups.flatMap(\.posts).count == 4)
    }

    @Test("Equal timestamps preserve feed order")
    func stableTimestampOrdering() {
        let first = post("first", root: "root", time: 2)
        let second = post("second", root: "root", time: 2)
        let root = post("root", time: 1)

        #expect(TimelineThreadGroup.grouping([first, second, root])[0].posts == [root, first, second])
    }

    @Test("Missing roots keep the same conversation identity when loaded later")
    func missingRootIdentity() {
        let reply = post("reply", root: "root", time: 2)
        let missing = TimelineThreadGroup.grouping([reply])[0]
        let complete = TimelineThreadGroup.grouping([reply, post("root", time: 1)])[0]

        #expect(missing.id == complete.id)
        #expect(missing.hasMissingRoot)
        #expect(!complete.hasMissingRoot)
    }

    @Test("Quotes and standalone reposts retain their own posts and attribution")
    func preservesIndependentPosts() {
        let root = post("root", time: 1)
        let quote = TimelineQuote(
            uri: root.uri, cid: root.cid, author: root.author,
            text: root.text, createdAt: root.createdAt
        )
        let quoting = post("quote", time: 3).replacingQuote(quote)
        let repost = TimelinePost(
            uri: "repost", cid: "cid", author: root.author, text: "Reposted",
            createdAt: Date(timeIntervalSince1970: 2), repostedBy: author
        )

        let groups = TimelineThreadGroup.grouping([quoting, repost, root])

        #expect(groups.map(\.id) == ["quote", "repost", "root"])
        #expect(groups.flatMap(\.posts) == [quoting, repost, root])
        #expect(groups[1].posts[0].repostedBy == author)
        #expect(TimelineThreadGroup.grouping([]).isEmpty)
    }

    @Test("Grouping retains every supplied occurrence without multiplying it")
    func retainsOccurrences() {
        let reply = post("reply", root: "root", time: 2)
        #expect(TimelineThreadGroup.grouping([reply, reply])[0].posts == [reply, reply])
    }

    @Test("Metadata enrichment preserves reply ancestry")
    func replacementsPreserveAncestry() {
        let reply = TimelinePost(
            uri: "reply", cid: "cid", author: author, text: "Reply", createdAt: .distantPast,
            replyRootURI: "root", replyRootCID: "root-cid", replyParentURI: "parent"
        )
        let replaced = [reply.replacingExternalEmbed(nil), reply.replacingQuote(nil)]
        for value in replaced {
            #expect(value.replyRootURI == "root")
            #expect(value.replyRootCID == "root-cid")
            #expect(value.replyParentURI == "parent")
        }
    }

    @Test("Timeline and thread sources decode parent references when supplied", arguments: [true, false])
    func decodesReplyParent(hasParent: Bool) async throws {
        let parent = hasParent ? #", "parent": {"uri":"at://did:plc:a/app.bsky.feed.post/parent", "cid":"parent-cid"}"# : ""
        let postJSON = """
        {"uri":"at://did:plc:a/app.bsky.feed.post/reply", "cid":"cid",
         "author":{"did":"did:plc:a", "handle":"a.test"},
         "record":{"text":"Reply", "createdAt":"2026-09-21T12:00:00Z",
                   "reply":{"root":{"uri":"at://did:plc:a/app.bsky.feed.post/root", "cid":"root-cid"}\(parent)}},
         "indexedAt":"2026-09-21T12:00:00Z"}
        """
        let timelineData = Data("{\"feed\":[{\"post\":\(postJSON)}]}".utf8)
        let threadData = Data("{\"thread\":{\"post\":\(postJSON)}}".utf8)
        let timeline = ATProtoTimelineSource { _ in timelineData }
        let thread = ATProtoPostThreadSource { _ in threadData }
        let timelinePost = try #require(await timeline.timeline(cursor: nil).posts.first)
        let uri = try ATURI("at://did:plc:a/app.bsky.feed.post/reply")
        let threadPost = try #require(await thread.thread(uri: uri).entries.first?.post)

        for value in [timelinePost, threadPost] {
            #expect(value.replyRootURI == "at://did:plc:a/app.bsky.feed.post/root")
            #expect(value.replyParentURI == (hasParent ? "at://did:plc:a/app.bsky.feed.post/parent" : nil))
        }
    }

    private var author: TimelineAuthor { TimelineAuthor(did: "did:plc:a", handle: "a.test") }

    @MainActor
    @Test("Cached conversations update after pagination and refresh")
    func modelUpdatesGroups() async throws {
        let reply = post("reply", root: "root", time: 2)
        let root = post("root", time: 1)
        let source = PagedSource(reply: reply, root: root)
        let model = TimelineModel(source: source)
        #expect(model.threadGroups.isEmpty)

        await model.load()
        #expect(model.threadGroups[0].id == "root")
        #expect(model.threadGroups[0].hasMissingRoot)
        await model.loadMore(after: reply)
        #expect(model.posts == [reply, root])
        #expect(model.threadGroups[0].posts == [root, reply])
        #expect(!model.threadGroups[0].hasMissingRoot)

        await model.refresh()
        #expect(model.threadGroups[0].posts == [reply])
        #expect(model.threadGroups[0].hasMissingRoot)
    }

    private struct PagedSource: TimelineSource {
        let reply: TimelinePost
        let root: TimelinePost

        func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
            if cursor == nil { return TimelinePage(posts: [reply], cursor: "next") }
            return TimelinePage(posts: [reply, root], cursor: nil)
        }
    }

    private func post(_ uri: String, root: String? = nil, time: TimeInterval) -> TimelinePost {
        TimelinePost(
            uri: uri, cid: "cid-\(uri)", author: author, text: uri,
            createdAt: Date(timeIntervalSince1970: time), replyRootURI: root
        )
    }
}
