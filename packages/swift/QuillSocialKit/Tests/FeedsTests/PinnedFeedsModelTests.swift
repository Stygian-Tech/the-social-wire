import ATProtoCore
import Foundation
import Testing
@testable import Feeds

/// A source that answers a different thing on each call, so reloads can be tested.
private actor ScriptedPinnedFeedsSource: PinnedFeedsSource {
    struct Failure: Error {}

    /// One entry per call; `nil` throws.
    private var answers: [[PinnedFeed]?]

    init(_ answers: [[PinnedFeed]?]) {
        self.answers = answers
    }

    func pinnedFeeds() async throws -> [PinnedFeed] {
        guard !answers.isEmpty else { throw Failure() }
        guard let answer = answers.removeFirst() else { throw Failure() }
        return answer
    }
}

@MainActor
@Suite struct PinnedFeedsModelTests {
    private static func feed(_ recordKey: String, _ name: String) throws -> PinnedFeed {
        PinnedFeed(
            uri: try ATURI("at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/\(recordKey)"),
            name: name
        )
    }

    @Test func nothingIsPinnedUntilTheFeedsLoad() {
        let model = PinnedFeedsModel(source: InMemoryPinnedFeedsSource())
        #expect(model.feeds.isEmpty)
        #expect(!model.isSubscribed(to: "at://did:plc:test/app.bsky.feed.generator/discover"))
        #expect(!model.didFail)
    }

    @Test func anAccountWithNoPinnedFeedsLoadsAnEmptySidebar() async {
        let model = PinnedFeedsModel(source: UnavailablePinnedFeedsSource())
        await model.load()
        #expect(model.feeds.isEmpty)
        #expect(!model.didFail)
        #expect(!model.isLoading)
    }

    @Test func feedsKeepThePinnedOrder() async throws {
        let discover = try Self.feed("whats-hot", "Discover")
        let science = try Self.feed("science", "Science")
        let model = PinnedFeedsModel(source: InMemoryPinnedFeedsSource(feeds: [discover, science]))
        await model.load()
        #expect(model.feeds == [discover, science])
        #expect(model.isSubscribed(to: discover.uri.description))
    }

    @Test func reloadPublishesNewlyPinnedFeeds() async throws {
        let discover = try Self.feed("whats-hot", "Discover")
        let science = try Self.feed("science", "Science")
        let model = PinnedFeedsModel(
            source: ScriptedPinnedFeedsSource([[discover], [discover, science]])
        )

        await model.load()
        #expect(model.feeds == [discover])

        await model.load()
        #expect(model.feeds == [discover, science])
    }

    @Test func metadataFailureOnReloadPreservesDisplayNamesAndUpdatedAccountOrder() async throws {
        let discover = try Self.feed("whats-hot", "Discover")
        let friends = try Self.feed("fu", "Friends")
        let unresolvedFriends = try Self.feed("fu", "fu")
        let unresolvedDiscover = try Self.feed("whats-hot", "whats-hot")
        let model = PinnedFeedsModel(source: ScriptedPinnedFeedsSource([
            [discover, friends], [unresolvedFriends, unresolvedDiscover],
        ]))

        await model.load()
        await model.load()

        #expect(model.feeds == [friends, discover])
    }

    @Test func aFailedLoadIsReportedRatherThanLookingLikeNothingIsPinned() async {
        let model = PinnedFeedsModel(source: InMemoryPinnedFeedsSource(fails: true))
        await model.load()
        #expect(model.didFail)
        #expect(model.feeds.isEmpty)
    }

    @Test func aFailedReloadKeepsTheFeedsTheSidebarAlreadyHad() async throws {
        let discover = try Self.feed("whats-hot", "Discover")
        let model = PinnedFeedsModel(source: ScriptedPinnedFeedsSource([[discover], nil]))

        await model.load()
        #expect(model.feeds == [discover])

        await model.load()
        #expect(model.didFail)
        #expect(model.feeds == [discover])
    }

    @Test func reloadingClearsAPreviousFailure() async throws {
        let discover = try Self.feed("whats-hot", "Discover")
        let model = PinnedFeedsModel(source: ScriptedPinnedFeedsSource([nil, [discover]]))

        await model.load()
        #expect(model.didFail)

        await model.load()
        #expect(!model.didFail)
        #expect(model.feeds == [discover])
    }

    @Test func duplicateFeedIdentifiersArePublishedOnlyOnce() async throws {
        let discover = try Self.feed("whats-hot", "Discover")
        let duplicate = try Self.feed("whats-hot", "Duplicate")
        let model = PinnedFeedsModel(
            source: InMemoryPinnedFeedsSource(feeds: [discover, duplicate])
        )

        await model.load()

        #expect(model.feeds == [discover])
    }

    @Test func staleMutationOffsetsAreIgnored() async throws {
        let discover = try Self.feed("whats-hot", "Discover")
        let model = PinnedFeedsModel(source: InMemoryPinnedFeedsSource(feeds: [discover]))
        await model.load()

        await model.move(fromOffsets: IndexSet(integer: 7), toOffset: 0)
        await model.remove(atOffsets: IndexSet(integer: 7))

        #expect(model.feeds == [discover])
        #expect(!model.isUpdating)
    }
}
