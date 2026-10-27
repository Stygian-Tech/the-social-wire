/// A pinned-feeds source with a fixed answer, for tests and previews.
public struct InMemoryPinnedFeedsSource: PinnedFeedsSource {
    /// Thrown when the source is configured to fail.
    public struct Failure: Error, Hashable {
        public init() {}
    }

    private let feeds: [PinnedFeed]
    private let fails: Bool

    public init(feeds: [PinnedFeed] = [], fails: Bool = false) {
        self.feeds = feeds
        self.fails = fails
    }

    public func pinnedFeeds() async throws -> [PinnedFeed] {
        guard !fails else { throw Failure() }
        return feeds
    }
}
