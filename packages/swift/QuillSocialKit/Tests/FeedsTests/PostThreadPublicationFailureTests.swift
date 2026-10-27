import Foundation
import Testing
@testable import Feeds

@Suite("Partial thread publication recovery")
struct PostThreadPublicationFailureTests {
    @Test("a failed second write reports only confirmed progress and an uncertain current outcome")
    func secondWriteFailure() async throws {
        let journal = PublicationJournal(failSecondWrite: true)
        let source = ATProtoPostActionSource(sessionDID: { "did:plc:viewer" }, procedure: { _, body in
            try await journal.write(body)
        })
        do {
            try await source.createThread([
                PostThreadDraft(text: "First", mentions: [:]),
                PostThreadDraft(text: "Second", mentions: [:]),
                PostThreadDraft(text: "Third", mentions: [:]),
            ])
            Issue.record("Expected a partial thread failure")
        } catch let failure as PostThreadPublicationFailure {
            #expect(failure.publishedCount == 1)
            #expect(failure.rootURI == "at://did:plc:viewer/app.bsky.feed.post/1")
            #expect(failure.parentCID == "cid1")
            #expect(failure.currentDraftOutcomeUncertain)
            #expect(await journal.bodies.count == 2)
        }
    }

    @Test("a safe retry sends only remaining drafts beneath the confirmed parent and original root")
    func resumesRemainingDrafts() async throws {
        let journal = PublicationJournal()
        let source = ATProtoPostActionSource(sessionDID: { "did:plc:viewer" }, procedure: { _, body in
            try await journal.write(body)
        }, blobUpload: { _, _ in try await journal.upload() })
        let original = TimelinePost(uri: "at://did:plc:original/app.bsky.feed.post/parent", cid: "parent-cid",
            author: TimelineAuthor(did: "did:plc:original", handle: "original.test"), text: "Original",
            createdAt: Date(), replyRootURI: "at://did:plc:original/app.bsky.feed.post/root", replyRootCID: "root-cid")
        let drafts = [
            PostThreadDraft(text: "First", mentions: [:]),
            PostThreadDraft(text: "Second", mentions: [:], images: [
                PostImageAttachment(data: Data([1]), mimeType: "image/jpeg", altText: "Image", width: 1, height: 1),
            ]),
            PostThreadDraft(text: "Third", mentions: [:]),
        ]
        do {
            try await source.createReplyThread(drafts, to: original)
            Issue.record("Expected the first image upload to fail")
        } catch let failure as PostThreadPublicationFailure {
            #expect(failure.publishedCount == 1)
            #expect(!failure.currentDraftOutcomeUncertain)
            let parent = TimelinePost(uri: try #require(failure.parentURI), cid: try #require(failure.parentCID),
                author: TimelineAuthor(did: "did:plc:viewer", handle: "viewer.test"), text: "First", createdAt: Date(),
                replyRootURI: failure.rootURI, replyRootCID: failure.rootCID)
            try await source.createReplyThread(Array(drafts.dropFirst(failure.publishedCount)), to: parent)
        }
        let records = try await journal.bodies.map { body in
            let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try #require(envelope["record"] as? [String: Any])
        }
        #expect(records.compactMap { $0["text"] as? String } == ["First", "Second", "Third"])
        let secondReply = try #require(records[1]["reply"] as? [String: Any])
        #expect((secondReply["root"] as? [String: String])?["cid"] == "root-cid")
        #expect((secondReply["parent"] as? [String: String])?["uri"] == "at://did:plc:viewer/app.bsky.feed.post/1")
        let thirdReply = try #require(records[2]["reply"] as? [String: Any])
        #expect((thirdReply["root"] as? [String: String])?["cid"] == "root-cid")
        #expect((thirdReply["parent"] as? [String: String])?["cid"] == "cid2")
    }
}

private actor PublicationJournal {
    var bodies: [Data] = []
    private var uploaded = false
    private let failSecondWrite: Bool

    init(failSecondWrite: Bool = false) { self.failSecondWrite = failSecondWrite }

    func write(_ body: Data) throws -> Data {
        bodies.append(body)
        if failSecondWrite && bodies.count == 2 { throw URLError(.networkConnectionLost) }
        return Data("{\"uri\":\"at://did:plc:viewer/app.bsky.feed.post/\(bodies.count)\",\"cid\":\"cid\(bodies.count)\"}".utf8)
    }

    func upload() throws -> Data {
        if !uploaded {
            uploaded = true
            throw URLError(.notConnectedToInternet)
        }
        return Data(#"{"blob":{"$type":"blob","ref":{"$link":"image-cid"},"mimeType":"image/jpeg","size":1}}"#.utf8)
    }
}
