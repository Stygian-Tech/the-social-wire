/// Where the account's pinned feeds come from.
///
/// `Sendable` and not actor-isolated, because the real implementation reads
/// `app.bsky.actor.getPreferences` from the account's PDS off the main actor.
public protocol PinnedFeedsSource: Sendable {
    func pinnedFeeds() async throws -> [PinnedFeed]
    func pinnedFeeds(onInitialFeeds: @escaping @Sendable ([PinnedFeed]) async -> Void) async throws -> [PinnedFeed]
    func updatePinnedFeeds(_ feeds: [PinnedFeed]) async throws
}

public extension PinnedFeedsSource {
    func pinnedFeeds(onInitialFeeds: @escaping @Sendable ([PinnedFeed]) async -> Void) async throws -> [PinnedFeed] {
        try await pinnedFeeds()
    }

    func updatePinnedFeeds(_ feeds: [PinnedFeed]) async throws {
        throw PinnedFeedsMutationUnsupported()
    }
}

public struct PinnedFeedsMutationUnsupported: Error, Sendable {
    public init() {}
}
