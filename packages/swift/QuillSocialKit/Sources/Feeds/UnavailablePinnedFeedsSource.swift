/// Reports no pinned feeds.
///
/// The app uses this until XRPC exists: pinned feeds live in the account's preferences, and
/// there is nothing yet that can read them. Swapping in the real source is the only change
/// needed — the model, the sidebar section, and its empty state already work.
public struct UnavailablePinnedFeedsSource: PinnedFeedsSource {
    public init() {}

    public func pinnedFeeds() async throws -> [PinnedFeed] { [] }
}
