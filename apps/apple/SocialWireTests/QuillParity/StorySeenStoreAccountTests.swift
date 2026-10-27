#if os(iOS)
import Feeds
import Foundation
import Testing
@testable import QuillSocialUI

@MainActor
struct StorySeenStoreAccountTests {
    @Test
    func seenStoriesRemainSeparateAcrossViewerChangesAndRestoration() throws {
        let suite = "StorySeenStoreAccountTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StorySeenStore(defaults: defaults)

        store.bind(viewerDID: "did:plc:viewerA")
        #expect(!store.hasSeen(story))
        store.markSeen(story)
        #expect(store.hasSeen(story))

        store.bind(viewerDID: "did:plc:viewerB")
        #expect(!store.hasSeen(story))
        store.markSeen(otherStory)
        #expect(store.hasSeen(otherStory))

        store.bind(viewerDID: "did:plc:viewerA")
        #expect(store.hasSeen(story))
        #expect(!store.hasSeen(otherStory))

        let restored = StorySeenStore(defaults: defaults)
        restored.bind(viewerDID: "did:plc:viewerB")
        #expect(!restored.hasSeen(story))
        #expect(restored.hasSeen(otherStory))
        restored.markSeen(story)
        #expect(restored.hasSeen(story))
    }

    @Test
    func sharedLegacyStateAndUnboundWritesDoNotBecomeViewerState() throws {
        let suite = "StorySeenStoreAccountTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([story.uri], forKey: "story.seenRecordURIs")
        let store = StorySeenStore(defaults: defaults)
        #expect(!store.hasSeen(story))
        store.markSeen(story)
        #expect(!store.hasSeen(story))

        store.bind(viewerDID: "did:plc:viewerA")
        #expect(!store.hasSeen(story))
        store.markSeen(story)
        store.bind(viewerDID: nil)
        #expect(store.recordURIs.isEmpty)
        store.markSeen(otherStory)
        store.bind(viewerDID: "did:plc:viewerA")
        #expect(store.hasSeen(story))
        #expect(!store.hasSeen(otherStory))
    }

    private var story: StoryRecord { makeStory(rkey: "one") }
    private var otherStory: StoryRecord { makeStory(rkey: "two") }

    private func makeStory(rkey: String) -> StoryRecord {
        StoryRecord(
            uri: "at://did:plc:author/blue.flashes.story.post/\(rkey)", blobCID: "blob",
            mimeType: "image/jpeg", createdAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 86_401)
        )
    }
}
#endif
