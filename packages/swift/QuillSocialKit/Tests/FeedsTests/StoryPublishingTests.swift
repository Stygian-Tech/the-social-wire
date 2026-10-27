import Foundation
import Testing
@testable import Feeds

struct StoryPublishingTests {
    @Test func photoRecordMatchesLiveFlashesContract() async throws {
        // Primary PDS observation, 2026-10-02:
        // https://eurosky.social/xrpc/com.atproto.repo.listRecords?repo=did:plc:24kqkpfy6z7avtgu3qg57vvl&collection=blue.flashes.story.post&limit=1
        // flashes.blue record 3mcd7uku5pu2r: image blob, text, createdAt, expiresInMinutes=1440.
        let source = ATProtoStorySource(
            sessionDID: { "did:plc:test" }, profileRequest: { _ in Data() },
            followsRequest: { _ in Data() }, recordsRequest: { _ in Data() },
            procedure: { nsid, body in
                #expect(nsid == "com.atproto.repo.createRecord")
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(object["repo"] as? String == "did:plc:test")
                #expect(object["collection"] as? String == "blue.flashes.story.post")
                let record = try #require(object["record"] as? [String: Any])
                #expect(record["$type"] as? String == "blue.flashes.story.post")
                #expect(record["expiresInMinutes"] as? Int == 1440)
                #expect(record["text"] as? String == "")
                #expect(record["createdAt"] as? String == "2026-10-02T12:00:00Z")
                let blob = try #require(record["image"] as? [String: Any])
                #expect(blob["size"] as? Int == 3)
                return Data(#"{"uri":"at://did:plc:test/blue.flashes.story.post/new"}"#.utf8)
            },
            blobUpload: { data, mime in
                #expect(data == Data([1, 2, 3]))
                #expect(mime == "image/jpeg")
                return Data(#"{"blob":{"$type":"blob","ref":{"$link":"bafk-test"},"mimeType":"image/jpeg","size":3}}"#.utf8)
            },
            now: { Date(timeIntervalSince1970: 1_790_942_400) }
        )
        #expect(try await source.publishPhoto(data: Data([1, 2, 3]), mimeType: "image/jpeg").hasSuffix("/new"))
    }

    @MainActor @Test func failedPublicationRetainsSelectedPhotoAndCanRetry() async {
        let model = StoryComposerModel()
        model.selectPhoto(data: Data([1]), mimeType: "image/jpeg")
        #expect(await model.publish(using: FailingPublisher()) == false)
        #expect(model.didFail)
        #expect(model.imageData == Data([1]))
        #expect(!model.isPublishing)
    }

    @MainActor @Test func duplicateSubmissionIsIgnoredWhilePublishing() async {
        let source = WaitingPublisher()
        let model = StoryComposerModel()
        model.selectPhoto(data: Data([1]), mimeType: "image/jpeg")
        let first = Task { await model.publish(using: source) }
        await source.waitUntilStarted()
        #expect(model.isPublishing)
        #expect(await model.publish(using: source) == false)
        model.selectPhoto(data: Data([2]), mimeType: "image/jpeg")
        #expect(model.imageData == Data([1]))
        await source.finish()
        #expect(await first.value)
        #expect(await source.calls == 1)
    }

    @Test func playbackTraversesAuthorsAndClampsBeginning() {
        let date = Date()
        func item(_ id: String, _ count: Int, isCurrentUser: Bool = false) -> StoryFeedItem {
            StoryFeedItem(author: StoryAuthor(did: id, handle: id, displayName: nil, avatarURL: nil),
                stories: (0..<count).map { StoryRecord(uri: "\(id)/\($0)", blobCID: "blob", mimeType: "image/jpeg", createdAt: date.addingTimeInterval(Double($0)), expiresAt: date.addingTimeInterval(86400)) }, isCurrentUser: isCurrentUser)
        }
        var playback = StoryPlayback(items: [item("empty", 0), item("one", 2, isCurrentUser: true), item("two", 1)], startingAuthorID: "one")
        playback.previous()
        #expect(playback.current?.id == "one/0")
        #expect(playback.current?.isCurrentUser == true)
        let advancedWithinAuthor = playback.next()
        #expect(advancedWithinAuthor)
        let advancedToAuthor = playback.next()
        #expect(advancedToAuthor)
        #expect(playback.current?.author.did == "two")
        #expect(playback.current?.isCurrentUser == false)
        let advancedPastEnd = playback.next()
        #expect(!advancedPastEnd)
        playback.previous()
        #expect(playback.current?.id == "one/1")
    }
}

private struct FailingPublisher: StoryPublishingSource {
    func publishPhoto(data: Data, mimeType: String) async throws -> String { throw URLError(.notConnectedToInternet) }
}

private actor WaitingPublisher: StoryPublishingSource {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var calls = 0
    func publishPhoto(data: Data, mimeType: String) async throws -> String {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func finish() { continuation?.resume(returning: "at://story/new"); continuation = nil }
}
