#if os(iOS)
import Foundation
import Feeds
import Testing
import UIKit
@testable import QuillSocialUI

@MainActor
struct PostComposerModelTests {
    @Test
    func altTextGenerationDefaultsToEnabled() {
        let settings = AppSettings()

        #expect(settings.allowsComposerAltTextGeneration)
        #expect(settings.allowsViewerAltTextGeneration)
    }

    @Test
    func updatesAltTextWithoutChangingAttachmentIdentity() throws {
        let model = PostComposerModel()
        model.addImage(data: Data([0x01]), mimeType: "image/jpeg")
        let attachment = try #require(model.drafts.first?.attachments.first)

        model.updateAltText("A blue bird on a wooden post.", for: attachment.id)

        let updated = try #require(model.drafts.first?.attachments.first)
        #expect(updated.id == attachment.id)
        #expect(updated.altText == "A blue bird on a wooden post.")
    }

    @Test
    func requiredAltTextPreventsPostingUntilEveryImageIsDescribed() {
        let model = PostComposerModel()
        model.addImage(data: Data([0x01]), mimeType: "image/jpeg")

        #expect(!model.canPost(requiringAltText: true))

        let attachmentID = model.drafts[0].attachments[0].id
        model.updateAltText("A waterfall between green cliffs.", for: attachmentID)

        #expect(model.canPost(requiringAltText: true))
    }

    @Test
    func reordersAttachments() {
        let model = PostComposerModel()
        model.addImage(data: Data([0x01]), mimeType: "image/jpeg")
        model.addImage(data: Data([0x02]), mimeType: "image/jpeg")
        let firstID = model.drafts[0].attachments[0].id
        let secondID = model.drafts[0].attachments[1].id

        model.moveAttachment(from: secondID, before: firstID)

        #expect(model.drafts[0].attachments.map(\.id) == [secondID, firstID])
    }

    @Test
    func preparesOversizedImageWithinUploadLimits() throws {
        let original = UIGraphicsImageRenderer(size: CGSize(width: 4_100, height: 100)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4_100, height: 100))
        }
        let data = try #require(original.pngData())

        let prepared = try #require(ComposerImageProcessor.prepare(data, mimeType: "image/png"))
        let image = try #require(UIImage(data: prepared.data))

        #expect(prepared.data.count <= ComposerImageProcessor.maximumByteCount)
        #expect(max(image.size.width, image.size.height) <= 4_000)
    }

    @Test
    func preservesCompliantImageWithoutUnnecessaryCompression() throws {
        let original = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let data = try #require(original.pngData())

        let prepared = try #require(ComposerImageProcessor.prepare(data, mimeType: "image/png"))

        #expect(prepared.data == data)
        #expect(prepared.mimeType == "image/png")
        #expect(ComposerImageProcessor.maximumByteCount == 2_000_000)
    }

    @Test
    func pickedGIFPublishesAnimatedExternalURIAndStaticThumbnail() throws {
        let model = PostComposerModel()
        let preview = try gifPreviewData()
        let gif = KlipyGIF(
            id: "gif", title: "Waving", description: "A person waves.",
            url: URL(string: "https://static.klipy.com/ii/example/full.gif?token=keep")!,
            previewURL: URL(string: "https://static.klipy.com/ii/example/tiny.gif")!,
            width: 640, height: 360
        )

        model.addGIF(gif, previewData: preview)
        model.updateText("Hello", for: model.activeDraftID)

        let draft = try #require(model.threadDrafts.first)
        let external = try #require(draft.external)
        let query = try #require(URLComponents(url: external.uri, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(draft.images.isEmpty)
        #expect(external.uri.path == "/ii/example/full.gif")
        #expect(query.contains(URLQueryItem(name: "ww", value: "640")))
        #expect(query.contains(URLQueryItem(name: "hh", value: "360")))
        #expect(query.contains(URLQueryItem(name: "token", value: "keep")))
        #expect(external.thumbnailMimeType == "image/jpeg")
        #expect(UIImage(data: try #require(external.thumbnailData)) != nil)
        #expect(external.description == "ALT: A person waves.")
        #expect(model.drafts[0].attachments[0].data == preview)
    }

    @Test
    func editingGIFAltTextUpdatesPublishedDescription() throws {
        let model = PostComposerModel()
        model.addGIF(testGIF(), previewData: try gifPreviewData())
        let attachment = try #require(model.drafts[0].attachments.first)

        model.updateAltText("A friendly wave.", for: attachment.id)

        #expect(model.threadDrafts[0].external?.description == "Alt: A friendly wave.")
        #expect(model.threadDrafts[0].external?.uri == attachment.sourceURL)
    }

    @Test
    func pickedGIFRejectsExistingPhotosWithoutRemovingThem() throws {
        let model = PostComposerModel()
        model.addImage(data: Data([0x01]), mimeType: "image/jpeg")
        let original = model.drafts[0].attachments

        model.addGIF(testGIF(), previewData: try gifPreviewData())

        #expect(model.drafts[0].attachments == original)
        #expect(model.errorMessage != nil)
        #expect(model.threadDrafts[0].images.count == 1)
        #expect(model.threadDrafts[0].external == nil)
    }

    @Test
    func photosRejectExistingGIFWithoutRemovingIt() throws {
        let model = PostComposerModel()
        model.addGIF(testGIF(), previewData: try gifPreviewData())
        let original = model.drafts[0].attachments

        model.addImage(data: Data([0x01]), mimeType: "image/jpeg")

        #expect(model.drafts[0].attachments == original)
        #expect(model.errorMessage != nil)
        #expect(model.threadDrafts[0].images.isEmpty)
        #expect(model.threadDrafts[0].external != nil)
    }

    @Test
    func removingGIFRestoresPhotoAttachments() throws {
        let model = PostComposerModel()
        model.addGIF(testGIF(), previewData: try gifPreviewData())
        let attachment = try #require(model.drafts[0].attachments.first)
        model.remove(attachment)
        model.addImage(data: Data([0x01]), mimeType: "image/jpeg")

        #expect(model.threadDrafts[0].external == nil)
        #expect(model.threadDrafts[0].images.count == 1)
    }

    @Test
    func invalidGIFPreviewPreservesEmptyDraft() {
        let model = PostComposerModel()
        model.addGIF(testGIF(), previewData: Data([0x01]))

        #expect(model.drafts[0].attachments.isEmpty)
        #expect(model.errorMessage != nil)
    }

    private func testGIF() -> KlipyGIF {
        KlipyGIF(
            id: "gif", title: "Waving", description: "A person waves.",
            url: URL(string: "https://static.klipy.com/ii/example/full.gif")!,
            previewURL: URL(string: "https://static.klipy.com/ii/example/tiny.gif")!,
            width: 640, height: 360
        )
    }

    private func gifPreviewData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        return try #require(image.pngData())
    }

    @Test
    func publishingFailureIncludesUnderlyingError() async {
        struct FailingSource: PostActionSource {
            struct UploadError: LocalizedError {
                var errorDescription: String? { "The PDS rejected the blob." }
            }

            func createPost(text: String, mentions: [String: String], images: [PostImageAttachment]) async throws {
                throw UploadError()
            }

            func createThread(_ drafts: [PostThreadDraft]) async throws { throw UploadError() }
            func createReplyThread(_ drafts: [PostThreadDraft], to post: TimelinePost) async throws { throw UploadError() }
            func createQuoteThread(_ drafts: [PostThreadDraft], quoting post: TimelinePost) async throws { throw UploadError() }
            func like(_ post: TimelinePost) async throws -> String { throw UploadError() }
            func unlike(recordURI: String) async throws { throw UploadError() }
            func repost(_ post: TimelinePost) async throws -> String { throw UploadError() }
            func undoRepost(recordURI: String) async throws { throw UploadError() }
            func reply(text: String, mentions: [String: String], to post: TimelinePost) async throws { throw UploadError() }
            func quote(text: String, mentions: [String: String], post: TimelinePost) async throws { throw UploadError() }
        }

        let model = PostComposerModel()
        model.updateText("Testing", for: model.activeDraftID)

        await model.send(using: FailingSource())

        #expect(model.errorMessage?.contains("The PDS rejected the blob.") == true)
    }
}

#endif
