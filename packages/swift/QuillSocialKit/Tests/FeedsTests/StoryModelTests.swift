import Feeds
import Testing

@MainActor
struct StoryModelTests {
    @Test func refreshKeepsExistingStoriesUntilCompleteResultRemovesThem() async throws {
        let source = ProgressiveStorySource()
        let model = StoryModel(source: source)
        await source.finish()
        await model.load()
        #expect(model.items.count == 2)

        await source.prepareForReloadWithoutFriend()
        let loading = Task { await model.load() }
        await source.waitForOwnPublication()
        #expect(model.items.map(\.author.did) == ["did:plc:current", "did:plc:friend"])

        await source.finish()
        await loading.value
        #expect(model.items.map(\.author.did) == ["did:plc:current"])
    }

    @Test func publishesOwnStoryWhileLoadingAndCoalescesDuplicateLoads() async throws {
        let source = ProgressiveStorySource()
        let model = StoryModel(source: source)
        let loading = Task { await model.load() }
        await source.waitForOwnPublication()

        #expect(model.items.map(\.author.did) == ["did:plc:current"])
        #expect(model.isLoading)
        await model.load()
        #expect(await source.loadCount == 1)

        await source.finish()
        await loading.value
        #expect(model.items.map(\.author.did) == ["did:plc:current", "did:plc:friend"])
        #expect(!model.isLoading)
        #expect(!model.didFail)
    }

    @Test func followingFailureRetainsAlreadyPublishedOwnStory() async throws {
        let source = ProgressiveStorySource(shouldFail: true)
        let model = StoryModel(source: source)
        let loading = Task { await model.load() }
        await source.waitForOwnPublication()
        await source.finish()
        await loading.value

        #expect(model.items.map(\.author.did) == ["did:plc:current"])
        #expect(model.didFail)
        #expect(!model.isLoading)
    }

    @Test func canceledLoadIgnoresLateSnapshotsWithoutShowingFailure() async throws {
        let source = ProgressiveStorySource()
        let model = StoryModel(source: source)
        let loading = Task { await model.load() }
        await source.waitForOwnPublication()
        loading.cancel()
        await source.finish()
        await loading.value

        #expect(model.items.map(\.author.did) == ["did:plc:current"])
        #expect(!model.didFail)
        #expect(!model.isLoading)
    }
}

private actor ProgressiveStorySource: StorySource {
    private let shouldFail: Bool
    private var ownPublished = false
    private var publicationWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var didFinish = false
    private var includesFriend = true
    private(set) var loadCount = 0

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func stories() async throws -> [StoryFeedItem] {
        try await stories { _ in }
    }

    func stories(
        onUpdate: @escaping @Sendable ([StoryFeedItem]) async -> Void
    ) async throws -> [StoryFeedItem] {
        loadCount += 1
        let own = StoryFeedItem(
            author: StoryAuthor(did: "did:plc:current", handle: "me.test"),
            stories: [],
            isCurrentUser: true
        )
        await onUpdate([own])
        ownPublished = true
        for waiter in publicationWaiters { waiter.resume() }
        publicationWaiters.removeAll()
        if !didFinish {
            await withCheckedContinuation { finishWaiter = $0 }
        }
        if shouldFail { throw FollowingFailure() }
        guard includesFriend else { return [own] }
        let friend = StoryFeedItem(
            author: StoryAuthor(did: "did:plc:friend", handle: "friend.test"),
            stories: [],
            isCurrentUser: false
        )
        await onUpdate([own, friend])
        return [own, friend]
    }

    func waitForOwnPublication() async {
        guard !ownPublished else { return }
        await withCheckedContinuation { publicationWaiters.append($0) }
    }

    func finish() {
        didFinish = true
        finishWaiter?.resume()
        finishWaiter = nil
    }

    func prepareForReloadWithoutFriend() {
        didFinish = false
        ownPublished = false
        includesFriend = false
    }

    private struct FollowingFailure: Error {}
}
