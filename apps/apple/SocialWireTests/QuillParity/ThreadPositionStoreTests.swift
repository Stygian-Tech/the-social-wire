#if os(iOS)
import ATProtoCore
import Feeds
import Foundation
import Testing
@testable import QuillSocialUI

@MainActor
struct ThreadPositionStoreTests {
    private struct Source: PostThreadSource {
        let value: PostThread

        func thread(uri: ATURI) async throws -> PostThread { value }
    }

    private actor RecoveringSource: PostThreadSource {
        let value: PostThread
        private(set) var requests = 0

        init(value: PostThread) { self.value = value }

        func thread(uri: ATURI) async throws -> PostThread {
            requests += 1
            if requests == 1 { throw URLError(.notConnectedToInternet) }
            return value
        }
    }

    @Test
    func transientFailureBacksOffThenRecoversWithoutRefetchingSuccessfulThreads() async throws {
        let author = TimelineAuthor(did: "did:plc:root", handle: "root.test")
        let rootURI = "at://did:plc:root/app.bsky.feed.post/root"
        let root = TimelinePost(
            uri: rootURI, cid: "root", author: author, text: "Root", createdAt: .now, replyCount: 1
        )
        let reply = TimelinePost(
            uri: "at://did:plc:root/app.bsky.feed.post/reply", cid: "reply", author: author,
            text: "Reply", createdAt: .now, replyRootURI: rootURI, replyingTo: author
        )
        let source = RecoveringSource(value: PostThread(entries: [
            ThreadEntry(post: root, depth: 0, isFocused: false),
            ThreadEntry(post: reply, depth: 1, isFocused: true, replyingTo: author),
        ]))
        var now = Date(timeIntervalSince1970: 0)
        let store = ThreadPositionStore(source: source, now: { now })

        await store.load(for: root)
        await store.load(for: reply)
        #expect(await source.requests == 1)
        #expect(store.position(for: root.uri) == nil)

        now = now.addingTimeInterval(30)
        await store.load(for: reply)
        #expect(await source.requests == 2)
        #expect(try #require(store.position(for: root.uri)).position == 1)
        #expect(try #require(store.position(for: reply.uri)).total == 2)

        now = now.addingTimeInterval(60)
        await store.load(for: root)
        #expect(await source.requests == 2)
    }

    @Test
    func doesNotCountRepliesBySomeoneOtherThanTheRootAuthor() async {
        let rootAuthor = TimelineAuthor(did: "did:plc:root", handle: "root.test")
        let replyAuthor = TimelineAuthor(did: "did:plc:reply", handle: "reply.test")
        let rootURI = "at://did:plc:root/app.bsky.feed.post/root"
        let root = TimelinePost(
            uri: rootURI,
            cid: "root-cid",
            author: rootAuthor,
            text: "Root",
            createdAt: .now,
            replyCount: 1
        )
        let reply = TimelinePost(
            uri: "at://did:plc:reply/app.bsky.feed.post/reply",
            cid: "reply-cid",
            author: replyAuthor,
            text: "Reply",
            createdAt: .now,
            replyRootURI: rootURI,
            replyingTo: rootAuthor
        )
        let thread = PostThread(entries: [
            ThreadEntry(post: root, depth: 0, isFocused: false),
            ThreadEntry(post: reply, depth: 1, isFocused: true, replyingTo: rootAuthor),
        ])
        let store = ThreadPositionStore(source: Source(value: thread))

        await store.load(for: reply)

        #expect(store.position(for: root.uri) == nil)
        #expect(store.position(for: reply.uri) == nil)
    }

    @Test
    func stopsCountingAfterAnotherAuthorBreaksTheChain() async throws {
        let op = TimelineAuthor(did: "did:plc:op", handle: "op.test")
        let other = TimelineAuthor(did: "did:plc:other", handle: "other.test")
        let rootURI = "at://did:plc:op/app.bsky.feed.post/root"
        func post(_ id: String, author: TimelineAuthor, root: String? = nil, replyingTo: TimelineAuthor? = nil) -> TimelinePost {
            TimelinePost(
                uri: "at://\(author.did)/app.bsky.feed.post/\(id)",
                cid: id,
                author: author,
                text: id,
                createdAt: .now,
                replyCount: id == "root" ? 1 : 0,
                replyRootURI: root,
                replyingTo: replyingTo
            )
        }
        let root = TimelinePost(
            uri: rootURI,
            cid: "root",
            author: op,
            text: "root",
            createdAt: .now,
            replyCount: 1
        )
        let selfReply = post("self", author: op, root: rootURI, replyingTo: op)
        let interruption = post("other", author: other, root: rootURI, replyingTo: op)
        let afterBreak = post("after", author: op, root: rootURI, replyingTo: other)
        let thread = PostThread(entries: [
            ThreadEntry(post: root, depth: 0, isFocused: false),
            ThreadEntry(post: selfReply, depth: 1, isFocused: false, replyingTo: op),
            ThreadEntry(post: interruption, depth: 2, isFocused: false, replyingTo: op),
            ThreadEntry(post: afterBreak, depth: 3, isFocused: true, replyingTo: other),
        ])
        let store = ThreadPositionStore(source: Source(value: thread))

        await store.load(for: afterBreak)

        let rootPosition = try #require(store.position(for: root.uri))
        let replyPosition = try #require(store.position(for: selfReply.uri))
        #expect(rootPosition.position == 1 && rootPosition.total == 2)
        #expect(replyPosition.position == 2 && replyPosition.total == 2)
        #expect(store.position(for: interruption.uri) == nil)
        #expect(store.position(for: afterBreak.uri) == nil)
    }

    @Test
    func threadScreenCountsOnlyTheInitialOPSequence() throws {
        let op = TimelineAuthor(did: "did:plc:op", handle: "op.test")
        let other = TimelineAuthor(did: "did:plc:other", handle: "other.test")
        func post(_ id: String, author: TimelineAuthor) -> TimelinePost {
            TimelinePost(
                uri: "at://\(author.did)/app.bsky.feed.post/\(id)",
                cid: id,
                author: author,
                text: id,
                createdAt: .now
            )
        }
        let root = post("root", author: op)
        let second = post("second", author: op)
        let third = post("third", author: op)
        let interruption = post("interruption", author: other)
        let laterOPReply = post("later", author: op)
        let thread = PostThread(entries: [
            ThreadEntry(post: root, depth: 0, isFocused: false),
            ThreadEntry(post: second, depth: 1, isFocused: false, replyingTo: op),
            ThreadEntry(post: third, depth: 2, isFocused: false, replyingTo: op),
            ThreadEntry(post: interruption, depth: 3, isFocused: true, replyingTo: op),
            ThreadEntry(post: laterOPReply, depth: 4, isFocused: false, replyingTo: other),
        ])

        let positions = ThreadEntriesView.authoredThreadPositions(in: thread)

        #expect(try #require(positions[root.id]).total == 3)
        #expect(try #require(positions[second.id]).position == 2)
        #expect(try #require(positions[third.id]).position == 3)
        #expect(positions[interruption.id] == nil)
        #expect(positions[laterOPReply.id] == nil)
    }
}

#endif
