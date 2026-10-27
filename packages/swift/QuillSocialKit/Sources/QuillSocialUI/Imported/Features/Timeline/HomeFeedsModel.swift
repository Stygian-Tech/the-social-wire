#if os(iOS)
import Feeds
import Observation

@MainActor
@Observable
final class HomeFeedsModel {
    typealias SourceFactory = @MainActor (PinnedFeed) -> any TimelineSource

    private let homeTimeline: TimelineModel
    private let sourceFactory: SourceFactory
    private let maximumCachedTimelines: Int
    // These are lookup bookkeeping, not view state. SwiftUI reads timeline(for:)
    // during body evaluation, so observing its LRU writes would invalidate that
    // same body on every cached lookup. Each TimelineModel observes its own state.
    @ObservationIgnored private var timelines: [String: TimelineModel] = [:]
    @ObservationIgnored private var accessOrder: [String] = []

    init(
        homeTimeline: TimelineModel,
        maximumCachedTimelines: Int = 5,
        sourceFactory: @escaping SourceFactory
    ) {
        self.homeTimeline = homeTimeline
        self.maximumCachedTimelines = max(maximumCachedTimelines, 1)
        self.sourceFactory = sourceFactory
    }

    func timeline(for item: HomeFeedItem) -> TimelineModel {
        guard let feed = item.feed else { return homeTimeline }
        if let timeline = timelines[item.id] {
            recordAccess(to: item.id)
            return timeline
        }

        let timeline = TimelineModel(source: sourceFactory(feed))
        timelines[item.id] = timeline
        recordAccess(to: item.id)
        evictInactiveTimelinesIfNeeded()
        return timeline
    }

    private func recordAccess(to id: String) {
        accessOrder.removeAll { $0 == id }
        accessOrder.append(id)
    }

    private func evictInactiveTimelinesIfNeeded() {
        while timelines.count > maximumCachedTimelines, let leastRecentlyUsedID = accessOrder.first {
            accessOrder.removeFirst()
            timelines[leastRecentlyUsedID] = nil
        }
    }
}

#endif
