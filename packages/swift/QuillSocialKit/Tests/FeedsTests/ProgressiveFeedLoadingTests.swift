import ATProtoCore
import Foundation
import Testing
@testable import Feeds

@MainActor
struct ProgressiveFeedLoadingTests {
    private actor Gate {
        var requests: [String] = []
        var pending: [String: CheckedContinuation<Void, Never>] = [:]
        var watchers: [(Int, CheckedContinuation<Void, Never>)] = []

        func suspend(_ key: String) async {
            await withCheckedContinuation { continuation in
                requests.append(key)
                pending[key] = continuation
                let ready = watchers.filter { requests.count >= $0.0 }
                watchers.removeAll { requests.count >= $0.0 }
                ready.forEach { $0.1.resume() }
            }
        }

        func waitForCount(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { watchers.append((count, $0)) }
        }

        func release(_ key: String) { pending.removeValue(forKey: key)?.resume() }
        func releaseAll() {
            let continuations = pending.values
            pending.removeAll()
            continuations.forEach { $0.resume() }
        }
        func count() -> Int { requests.count }
    }

    private struct Base: TimelineSource {
        let posts: [TimelinePost]
        func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
            TimelinePage(posts: posts, cursor: "next")
        }
    }

    private actor ProgressiveSource: TimelineSource {
        let gate: Gate
        var generation = 0
        let delaysInitialPage: Bool
        init(gate: Gate, delaysInitialPage: Bool = false) {
            self.gate = gate
            self.delaysInitialPage = delaysInitialPage
        }
        func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
            TimelinePage(posts: [], cursor: nil)
        }
        func timeline(
            cursor: String?, limit: Int,
            onInitialPage: @escaping @Sendable (TimelinePage) async -> Void
        ) async throws -> TimelinePage {
            generation += 1
            let current = generation
            if delaysInitialPage { await gate.suspend("start-\(current)") }
            await onInitialPage(TimelinePage(posts: [Self.post("raw-\(current)")], cursor: "next"))
            await gate.suspend("\(current)")
            return TimelinePage(posts: [Self.post("raw-\(current)", text: "enriched-\(current)")], cursor: "next")
        }
        static func post(_ id: String, text: String? = nil) -> TimelinePost {
            TimelinePost(uri: id, cid: id, author: TimelineAuthor(did: "did:plc:test", handle: "test.example"),
                         text: text ?? id, createdAt: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func timelinePublishesBeforeEnrichmentAndIgnoresSupersededResults() async throws {
        let gate = Gate()
        let source = ProgressiveSource(gate: gate)
        let model = TimelineModel(source: source)
        let first = Task { await model.load() }
        await gate.waitForCount(1)
        #expect(model.posts.map(\.text) == ["raw-1"])
        #expect(!model.isLoading)
        let last = try #require(model.posts.last)
        await model.loadMore(after: last)
        #expect(await gate.count() == 1)

        let refresh = Task { await model.refresh() }
        await gate.waitForCount(2)
        await gate.release("1")
        await first.value
        #expect(model.posts.map(\.text) == ["raw-2"])
        await gate.release("2")
        await refresh.value
        #expect(model.posts.map(\.text) == ["enriched-2"])
    }

    @Test func timelineLimitsMetadataConcurrencyAndKeepsOrder() async throws {
        let gate = Gate()
        let posts = try (0..<6).map { index in
            return TimelinePost(uri: "post-\(index)", cid: "cid", author: TimelineAuthor(did: "did:plc:test", handle: "test.example"),
                         text: "\(index)", createdAt: Date(timeIntervalSince1970: 0),
                         externalEmbed: TimelineExternalEmbed(uri: try #require(URL(string: "https://example.test/\(index)")), title: "Article", description: ""))
        }
        let source = StandardSiteEnrichedTimelineSource(base: Base(posts: posts), resolver: { url in
            await gate.suspend(url.lastPathComponent)
            return nil
        })
        let model = TimelineModel(source: source)
        let load = Task { await model.load() }
        await gate.waitForCount(4)
        #expect(model.posts == posts)
        #expect(!model.isLoading)
        #expect(!model.canLoadMore)
        #expect(model.paginationRevision == 0)
        #expect(await gate.count() == 4)
        await gate.release("0")
        await gate.waitForCount(5)
        await gate.release("1")
        await gate.waitForCount(6)
        await gate.releaseAll()
        await load.value
        #expect(model.posts == posts)
        #expect(model.canLoadMore)
        #expect(model.paginationRevision == 1)
    }

    @Test func pinnedFeedsPublishImmediatelyAndBoundConcurrentLookups() async throws {
        let gate = Gate()
        let values = (0..<6).map { "at://did:plc:test/app.bsky.feed.generator/feed\($0)" }
        let preferences = try JSONSerialization.data(withJSONObject: ["preferences": [[
            "$type": "app.bsky.actor.defs#savedFeedsPref", "pinned": values + [values[0]],
        ]]])
        let source = ATProtoPinnedFeedsSource(preferencesRequest: { preferences }, feedRequest: { uri in
            let key = String(try #require(uri.split(separator: "/").last))
            await gate.suspend(key)
            if key == "feed0" { throw URLError(.cannotFindHost) }
            return Data("{\"view\":{\"displayName\":\"Resolved \(key)\"}}".utf8)
        })
        let model = PinnedFeedsModel(source: source)
        let load = Task { await model.load() }
        await gate.waitForCount(4)
        #expect(model.feeds.map(\.name) == (0..<6).map { "feed\($0)" })
        #expect(await gate.count() == 4)
        await gate.release("feed0")
        await gate.waitForCount(5)
        await gate.release("feed1")
        await gate.waitForCount(6)
        #expect(model.feeds[1].name == "Resolved feed1")
        #expect(model.feeds[2].name == "feed2")
        await gate.releaseAll()
        await load.value
        #expect(!model.didFail)
        #expect(model.feeds.map(\.name) == ["feed0"] + (1..<6).map { "Resolved feed\($0)" })
        #expect(model.feeds.map { $0.uri.description } == values)
    }

    @Test func editingPinnedFeedsDuringResolutionDoesNotRestoreRemovedFeed() async throws {
        let gate = Gate()
        let values = (0..<2).map { "at://did:plc:test/app.bsky.feed.generator/feed\($0)" }
        let preferences = try JSONSerialization.data(withJSONObject: ["preferences": [[
            "$type": "app.bsky.actor.defs#savedFeedsPref", "pinned": values,
        ]]])
        let source = ATProtoPinnedFeedsSource(
            preferencesRequest: { preferences }, preferencesUpdate: { _ in },
            feedRequest: { uri in
                await gate.suspend(uri)
                return Data("{\"view\":{\"displayName\":\"Resolved\"}}".utf8)
            }
        )
        let model = PinnedFeedsModel(source: source)
        let load = Task { await model.load() }
        await gate.waitForCount(2)
        await model.remove(atOffsets: IndexSet(integer: 0))
        await gate.releaseAll()
        await load.value
        #expect(model.feeds.map { $0.uri.description } == [values[1]])
    }

    @Test func visibleRefreshReturnsBeforeOptionalMetadataFinishes() async {
        let gate = Gate()
        let model = TimelineModel(source: ProgressiveSource(gate: gate))
        let refresh = Task { await model.refreshVisibleContent() }
        await gate.waitForCount(1)
        await refresh.value
        #expect(model.posts.map(\.text) == ["raw-1"])
        #expect(!model.isLoading)
        // A second gesture also completes while the old resolver is still pending.
        let next = Task { await model.refreshVisibleContent() }
        await gate.waitForCount(2)
        await next.value
        #expect(model.posts.map(\.text) == ["raw-2"])
        await gate.releaseAll()
    }

    @Test func canceledRefreshCallerReleasesWaiterWithoutCancelingOwnedLoad() async {
        let gate = Gate()
        let model = TimelineModel(source: ProgressiveSource(gate: gate, delaysInitialPage: true))
        let refresh = Task { await model.refreshVisibleContent() }
        await gate.waitForCount(1)
        refresh.cancel()
        await refresh.value
        #expect(model.posts.isEmpty)
        await gate.release("start-1")
        await gate.waitForCount(2)
        #expect(model.posts.map(\.text) == ["raw-1"])
        #expect(!model.isLoading)
        await gate.releaseAll()
    }

    @Test func visibleRefreshAlsoWorksWithNonprogressiveSources() async {
        let post = ProgressiveSource.post("legacy")
        let model = TimelineModel(source: Base(posts: [post]))
        await model.refreshVisibleContent()
        #expect(model.posts == [post])
        #expect(!model.isLoading)
    }

}
