import Foundation
import Testing
@testable import Feeds

@MainActor
struct TimelineModelTests {
    private actor DuplicateSource: TimelineSource {
        let progressive: Bool
        let repeatsCursor: Bool
        private var requests: [String?] = []

        init(progressive: Bool = false, repeatsCursor: Bool = false) {
            self.progressive = progressive
            self.repeatsCursor = repeatsCursor
        }

        func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
            requests.append(cursor)
            if cursor == nil {
                return TimelinePage(posts: [post("one", "first"), post("one", "duplicate"), post("two", "second")], cursor: "next")
            }
            return TimelinePage(posts: [post("two", "updated"), post("three", "third"), post("three", "duplicate")], cursor: repeatsCursor ? cursor : nil)
        }

        func timeline(cursor: String?, limit: Int, onInitialPage: @escaping @Sendable (TimelinePage) async -> Void) async throws -> TimelinePage {
            let page = try await timeline(cursor: cursor, limit: limit)
            guard progressive else { return page }
            await onInitialPage(page)
            return TimelinePage(posts: [post("one", "enriched-first"), post("one", "enriched-duplicate"), post("two", "enriched-second")], cursor: page.cursor)
        }

        func requestCount() -> Int { requests.count }

        private func post(_ id: String, _ text: String) -> TimelinePost {
            TimelinePost(uri: id, cid: id, author: TimelineAuthor(did: "did:plc:test", handle: "test.example"), text: text, createdAt: Date(timeIntervalSince1970: 0))
        }
    }

    @Test(arguments: [false, true])
    func initialPagesKeepFirstOccurrenceAndStableOrder(progressive: Bool) async throws {
        let source = DuplicateSource(progressive: progressive)
        let model = TimelineModel(source: source)
        await model.load()
        #expect(model.posts.map(\.id) == ["one", "two"])
        #expect(model.posts.map(\.text) == (progressive ? ["enriched-first", "enriched-second"] : ["first", "second"]))
        await model.refresh()
        #expect(model.posts.map(\.id) == ["one", "two"])
    }

    @Test
    func paginationDeduplicatesUpdatesAndStopsRepeatedCursor() async throws {
        let source = DuplicateSource(repeatsCursor: true)
        let model = TimelineModel(source: source)
        await model.load()
        await model.loadMore(after: try #require(model.posts.last))
        #expect(model.posts.map(\.id) == ["one", "two", "three"])
        #expect(model.posts.map(\.text) == ["first", "updated", "third"])
        #expect(!model.canLoadMore)
        await model.loadMore(after: try #require(model.posts.last))
        #expect(await source.requestCount() == 2)
        await model.refresh()
        #expect(model.canLoadMore)
    }

    private actor CursorSequenceSource: TimelineSource {
        let initialCursor: String?
        let followingCursors: [String: String]
        let emptyPageCursors: Set<String>
        let duplicatePageCursors: Set<String>
        private var requests: [String?] = []

        init(initialCursor: String?, followingCursors: [String: String], emptyPageCursors: Set<String> = [], duplicatePageCursors: Set<String> = []) {
            self.initialCursor = initialCursor
            self.followingCursors = followingCursors
            self.emptyPageCursors = emptyPageCursors
            self.duplicatePageCursors = duplicatePageCursors
        }

        func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
            requests.append(cursor)
            let id = cursor ?? "initial"
            let postID = duplicatePageCursors.contains(id) ? "initial" : id
            let post = TimelinePost(uri: postID, cid: postID, author: TimelineAuthor(did: "did:plc:test", handle: "test.example"), text: id, createdAt: Date(timeIntervalSince1970: 0))
            return TimelinePage(posts: emptyPageCursors.contains(id) ? [] : [post], cursor: cursor.map { followingCursors[$0] } ?? initialCursor)
        }

        func requestedCursors() -> [String?] { requests }
    }

    @Test
    func paginationStopsMultiPageCursorCyclesAndRefreshStartsNewSequence() async throws {
        let source = CursorSequenceSource(initialCursor: "a", followingCursors: ["a": "b", "b": "a"])
        let model = TimelineModel(source: source)
        await model.load()
        await model.loadMore(after: try #require(model.posts.last))
        #expect(model.canLoadMore)
        await model.loadMore(after: try #require(model.posts.last))
        #expect(!model.canLoadMore)
        await model.loadMore(after: try #require(model.posts.last))
        #expect(await source.requestedCursors() == [nil, "a", "b"])
        #expect(model.posts.map(\.id) == ["initial", "a", "b"])
        await model.refresh()
        #expect(model.canLoadMore)
        await model.loadMore(after: try #require(model.posts.last))
        #expect(await source.requestedCursors() == [nil, "a", "b", nil, "a"])
        #expect(model.posts.map(\.id) == ["initial", "a"])
    }

    @Test(arguments: [false, true])
    func pageWithoutNovelPostsWithAdvancingCursorInvalidatesVisiblePaginationSentinel(empty: Bool) async throws {
        let source = CursorSequenceSource(initialCursor: "a", followingCursors: ["a": "b"], emptyPageCursors: empty ? ["a"] : [], duplicatePageCursors: empty ? [] : ["a"])
        let model = TimelineModel(source: source)
        await model.load()
        let previousRevision = model.paginationRevision
        let last = try #require(model.posts.last)
        await model.loadMore(after: last)
        #expect(model.posts.last?.id == last.id)
        #expect(model.canLoadMore)
        #expect(model.paginationRevision > previousRevision)
        await model.loadMore(after: last)
        #expect(model.posts.map(\.id) == ["initial", "b"])
        #expect(!model.canLoadMore)
    }

    @Test(arguments: [false, true])
    func emptyCursorEndsPagination(inInitialPage: Bool) async throws {
        let source = CursorSequenceSource(initialCursor: inInitialPage ? "" : "a", followingCursors: ["a": ""])
        let model = TimelineModel(source: source)
        await model.load()
        if !inInitialPage {
            #expect(model.canLoadMore)
            await model.loadMore(after: try #require(model.posts.last))
        }
        #expect(!model.canLoadMore)
        await model.loadMore(after: try #require(model.posts.last))
        #expect(await source.requestedCursors() == (inInitialPage ? [nil] : [nil, "a"]))
    }

    private actor SuspendedSource: TimelineSource {
        private var initial = true
        private var pending: [String: CheckedContinuation<TimelinePage, any Error>] = [:]
        private var observers: [String: CheckedContinuation<Void, Never>] = [:]

        func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
            if initial {
                initial = false
                return TimelinePage(posts: [Self.post("initial")], cursor: "old-page")
            }
            let key = cursor ?? "refresh"
            return try await withCheckedThrowingContinuation { continuation in
                pending[key] = continuation
                observers.removeValue(forKey: key)?.resume()
            }
        }

        func waitForRequest(_ key: String) async {
            if pending[key] != nil { return }
            await withCheckedContinuation { observers[key] = $0 }
        }

        func complete(_ key: String, page: TimelinePage) {
            pending.removeValue(forKey: key)?.resume(returning: page)
        }

        func fail(_ key: String) {
            pending.removeValue(forKey: key)?.resume(throwing: URLError(.notConnectedToInternet))
        }

        static func post(_ id: String) -> TimelinePost {
            TimelinePost(
                uri: "at://did:plc:test/app.bsky.feed.post/\(id)", cid: id,
                author: TimelineAuthor(did: "did:plc:test", handle: "test.example"),
                text: id, createdAt: Date(timeIntervalSince1970: 0)
            )
        }
    }

    @Test(arguments: [false, true])
    func refreshDiscardsOlderPaginationRegardlessOfCompletionOrder(oldPageFinishesFirst: Bool) async throws {
        let source = SuspendedSource()
        let model = TimelineModel(source: source)
        await model.load()
        let initial = try #require(model.posts.first)
        let pagination = Task { await model.loadMore(after: initial) }
        await source.waitForRequest("old-page")
        let refresh = Task { await model.refresh() }
        await source.waitForRequest("refresh")

        let oldPage = TimelinePage(posts: [SuspendedSource.post("stale")], cursor: "stale-cursor")
        let freshPage = TimelinePage(posts: [SuspendedSource.post("fresh")], cursor: "fresh-page")
        if oldPageFinishesFirst {
            await source.complete("old-page", page: oldPage)
            await pagination.value
            await source.complete("refresh", page: freshPage)
            await refresh.value
        } else {
            await source.complete("refresh", page: freshPage)
            await refresh.value
            await source.complete("old-page", page: oldPage)
            await pagination.value
        }
        #expect(model.posts.map(\.text) == ["fresh"])
        #expect(!model.isLoadingMore && !model.didFail)

        let fresh = try #require(model.posts.first)
        let nextPage = Task { await model.loadMore(after: fresh) }
        await source.waitForRequest("fresh-page")
        await source.complete("fresh-page", page: TimelinePage(posts: [SuspendedSource.post("next")], cursor: nil))
        await nextPage.value
        #expect(model.posts.map(\.text) == ["fresh", "next"])
    }

    @Test
    func supersededPaginationFailureDoesNotMarkRefreshedFeedFailed() async throws {
        let source = SuspendedSource()
        let model = TimelineModel(source: source)
        await model.load()
        let initial = try #require(model.posts.first)
        let pagination = Task { await model.loadMore(after: initial) }
        await source.waitForRequest("old-page")
        let refresh = Task { await model.refresh() }
        await source.waitForRequest("refresh")
        await source.complete("refresh", page: TimelinePage(posts: [SuspendedSource.post("fresh")], cursor: "fresh-page"))
        await refresh.value
        let fresh = try #require(model.posts.first)
        let nextPage = Task { await model.loadMore(after: fresh) }
        await source.waitForRequest("fresh-page")
        await source.fail("old-page")
        await pagination.value
        #expect(!model.didFail && model.isLoadingMore)
        await source.complete("fresh-page", page: TimelinePage(posts: [], cursor: nil))
        await nextPage.value
        #expect(!model.didFail && !model.isLoadingMore)
        #expect(model.posts.map(\.text) == ["fresh"])
    }
}
