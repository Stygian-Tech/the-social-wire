import Foundation
import Testing
@testable import Feeds

@MainActor
struct StoryPublicationRefreshTests {
    @Test func failedRefreshAfterSuccessfulCreateDoesNotOfferPublicationRetry() async {
        let source = RefreshFailingPublisher()
        let stories = StoryModel(source: source)
        let composer = StoryComposerModel()
        composer.selectPhoto(data: Data([1]), mimeType: "image/jpeg")
        #expect(await composer.publish(using: stories))
        #expect(!composer.didFail)
        #expect(stories.didFail)
        #expect(await source.publishCount == 1)
        #expect(await source.loadCount == 1)
    }

    @Test func successfulPublicationRefreshesAfterAnOlderSnapshotFinishes() async throws {
        let source = RefreshFailingPublisher(holdInitialLoad: true)
        let stories = StoryModel(source: source)
        let loading = Task { await stories.load() }
        await source.waitForInitialLoad()
        let publishing = Task { try await stories.publishPhoto(data: Data([1]), mimeType: "image/jpeg") }
        await source.waitForPublication()
        await source.finishInitialLoad()
        await loading.value
        #expect(try await publishing.value == "at://did:plc:test/blue.flashes.story.post/new")
        #expect(await source.publishCount == 1)
        #expect(await source.loadCount == 2)
        #expect(stories.didFail)
    }
}

private actor RefreshFailingPublisher: StorySource, StoryPublishingSource {
    private let holdInitialLoad: Bool
    private var initialWaiter: CheckedContinuation<Void, Never>?
    private var loadObservers: [CheckedContinuation<Void, Never>] = []
    private var publicationObservers: [CheckedContinuation<Void, Never>] = []
    private(set) var publishCount = 0
    private(set) var loadCount = 0

    init(holdInitialLoad: Bool = false) { self.holdInitialLoad = holdInitialLoad }

    func stories() async throws -> [StoryFeedItem] {
        loadCount += 1
        if holdInitialLoad, loadCount == 1 {
            await withCheckedContinuation { continuation in
                initialWaiter = continuation
                loadObservers.forEach { $0.resume() }
                loadObservers.removeAll()
            }
            return []
        }
        throw URLError(.notConnectedToInternet)
    }

    func publishPhoto(data: Data, mimeType: String) async throws -> String {
        publishCount += 1
        publicationObservers.forEach { $0.resume() }
        publicationObservers.removeAll()
        return "at://did:plc:test/blue.flashes.story.post/new"
    }

    func waitForInitialLoad() async {
        guard initialWaiter == nil else { return }
        await withCheckedContinuation { loadObservers.append($0) }
    }

    func waitForPublication() async {
        guard publishCount == 0 else { return }
        await withCheckedContinuation { publicationObservers.append($0) }
    }

    func finishInitialLoad() {
        initialWaiter?.resume()
        initialWaiter = nil
    }
}
