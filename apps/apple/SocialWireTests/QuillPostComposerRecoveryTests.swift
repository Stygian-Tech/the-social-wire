#if os(iOS)
import Feeds
import Foundation
import Testing
@testable import QuillSocialUI

@Suite("Quill composer partial publication")
@MainActor
struct QuillPostComposerRecoveryTests {
    @Test("a failed media preparation removes confirmed drafts and retries only the remaining reply")
    func keepsUnsentDrafts() async throws {
        let journal = ComposerPublicationJournal()
        let source = ATProtoPostActionSource(sessionDID: { "did:plc:viewer" }, procedure: { _, body in
            try await journal.write(body)
        }, blobUpload: { _, _ in try await journal.upload() })
        let model = PostComposerModel()
        model.updateText("First", for: model.activeDraftID)
        model.addDraft()
        let remainingID = model.activeDraftID
        model.updateText("Second", for: remainingID)
        model.addImage(data: Data([1]), mimeType: "image/jpeg")
        await model.send(using: source)
        #expect(!model.didPost)
        #expect(model.drafts.count == 1)
        #expect(model.drafts.first?.id == remainingID)
        #expect(model.canPost)
        guard case .reply(let parent) = model.context else {
            Issue.record("Remaining draft did not become a reply to the confirmed post")
            return
        }
        #expect(parent.cid == "cid1")
        #expect(parent.replyRootCID == "cid1")
        await model.send(using: source)
        #expect(model.didPost)
        #expect(await journal.writeCount == 2)
    }

    @Test("an ambiguous write keeps the draft and blocks a second send")
    func blocksAmbiguousRetry() async throws {
        let journal = ComposerPublicationJournal(failWrite: true)
        let source = ATProtoPostActionSource(sessionDID: { "did:plc:viewer" }, procedure: { _, body in
            try await journal.write(body)
        })
        let model = PostComposerModel()
        model.updateText("Possibly published", for: model.activeDraftID)
        await model.send(using: source)
        #expect(model.hasUncertainPublication)
        #expect(!model.canPost)
        #expect(model.drafts.count == 1)
        await model.send(using: source)
        #expect(await journal.writeCount == 1)
    }
}

private actor ComposerPublicationJournal {
    var writeCount = 0
    private var uploaded = false
    private let failWrite: Bool

    init(failWrite: Bool = false) { self.failWrite = failWrite }

    func write(_ body: Data) throws -> Data {
        writeCount += 1
        if failWrite { throw URLError(.networkConnectionLost) }
        return Data("{\"uri\":\"at://did:plc:viewer/app.bsky.feed.post/\(writeCount)\",\"cid\":\"cid\(writeCount)\"}".utf8)
    }

    func upload() throws -> Data {
        if !uploaded {
            uploaded = true
            throw URLError(.notConnectedToInternet)
        }
        return Data(#"{"blob":{"$type":"blob","ref":{"$link":"image-cid"},"mimeType":"image/jpeg","size":1}}"#.utf8)
    }
}
#endif
