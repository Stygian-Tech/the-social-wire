#if os(iOS)
import ATProtoCore
import Feeds
import Observation
import Synchronization
import Testing
@testable import QuillSocialUI

@MainActor
struct HomeFeedsModelTests {
    private struct EmptySource: TimelineSource {
        func timeline(cursor: String?, limit: Int) async throws -> TimelinePage {
            TimelinePage(posts: [], cursor: nil)
        }
    }

    @Test
    func evictsLeastRecentlyUsedInactiveTimeline() throws {
        var creationCounts: [String: Int] = [:]
        let model = HomeFeedsModel(
            homeTimeline: TimelineModel(source: EmptySource()),
            maximumCachedTimelines: 2
        ) { feed in
            creationCounts[feed.id.description, default: 0] += 1
            return EmptySource()
        }
        let first = try feed(number: 1)
        let second = try feed(number: 2)
        let third = try feed(number: 3)

        _ = model.timeline(for: HomeFeedItem(feed: first))
        _ = model.timeline(for: HomeFeedItem(feed: second))
        _ = model.timeline(for: HomeFeedItem(feed: first))
        _ = model.timeline(for: HomeFeedItem(feed: third))
        _ = model.timeline(for: HomeFeedItem(feed: second))

        #expect(creationCounts[first.id.description] == 1)
        #expect(creationCounts[second.id.description] == 2)
        #expect(creationCounts[third.id.description] == 1)
    }

    @Test
    func cachedLookupAndEvictionDoNotInvalidateAViewObserver() throws {
        let model = HomeFeedsModel(
            homeTimeline: TimelineModel(source: EmptySource()),
            maximumCachedTimelines: 2,
            sourceFactory: { _ in EmptySource() }
        )
        let first = HomeFeedItem(feed: try feed(number: 1))
        let expectedTimeline = model.timeline(for: first)
        let invalidations = Mutex(0)
        withObservationTracking {
            _ = model.timeline(for: first)
        } onChange: {
            invalidations.withLock { $0 += 1 }
        }

        for _ in 0..<20 {
            #expect(model.timeline(for: first) === expectedTimeline)
        }
        _ = model.timeline(for: HomeFeedItem(feed: try feed(number: 2)))
        _ = model.timeline(for: HomeFeedItem(feed: try feed(number: 3)))
        #expect(invalidations.withLock { $0 } == 0)
    }

    @Test
    func childTimelineLoadingRemainsObservableAfterIgnoringCacheBookkeeping() async throws {
        let model = HomeFeedsModel(
            homeTimeline: TimelineModel(source: EmptySource()),
            sourceFactory: { _ in EmptySource() }
        )
        let item = HomeFeedItem(feed: try feed(number: 1))
        let timeline = model.timeline(for: item)
        let invalidations = Mutex(0)
        withObservationTracking {
            _ = model.timeline(for: item).isLoading
        } onChange: {
            invalidations.withLock { $0 += 1 }
        }

        _ = model.timeline(for: item)
        #expect(invalidations.withLock { $0 } == 0)
        await timeline.load()
        #expect(invalidations.withLock { $0 } == 1)
        #expect(!timeline.isLoading)
    }

    private func feed(number: Int) throws -> PinnedFeed {
        PinnedFeed(
            uri: try ATURI("at://did:plc:test/app.bsky.feed.generator/\(number)"),
            name: "Feed \(number)"
        )
    }
}

#endif
