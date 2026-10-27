#if os(iOS)
import Feeds
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class PostComposerModel {
    static let maximumImageCount = 10
    static let maximumCharacterCount = 300

    enum Context {
        case post
        case reply(TimelinePost)
        case quote(TimelinePost)

        var referencedPost: TimelinePost? {
            switch self {
            case .post: nil
            case .reply(let post), .quote(let post): post
            }
        }
    }

    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let data: Data
        let mimeType: String
        let width: Int
        let height: Int
        var altText: String
        var sourceURL: URL? = nil
        var sourceTitle: String = ""
        var thumbnailData: Data? = nil
    }

    struct Draft: Identifiable {
        let id = UUID()
        var text = ""
        var mentions: [String: String] = [:]
        var attachments: [Attachment] = []
        var linkPreview: TimelineExternalEmbed?
        var externalAttachment: PostExternalAttachment?
    }

    private(set) var drafts: [Draft]
    private(set) var activeDraftID: UUID
    private(set) var context: Context
    private(set) var isSending = false
    private(set) var didPost = false
    private(set) var hasUncertainPublication = false
    var errorMessage: String?

    init(context: Context = .post) {
        let draft = Draft()
        drafts = [draft]
        activeDraftID = draft.id
        self.context = context
    }

    var activeAttachmentCount: Int {
        drafts.first { $0.id == activeDraftID }?.attachments.count ?? 0
    }

    var canPost: Bool {
        canPost(requiringAltText: false)
    }

    func canPost(requiringAltText: Bool) -> Bool {
        !hasUncertainPublication && !drafts.isEmpty && drafts.enumerated().allSatisfy { index, draft in
            let hasContent = !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.attachments.isEmpty
            let isEmptyQuote: Bool
            if index == 0, !hasContent, case .quote = context {
                isEmptyQuote = true
            } else {
                isEmptyQuote = false
            }
            let hasRequiredAltText = !requiringAltText || draft.attachments.allSatisfy {
                !$0.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return (hasContent || isEmptyQuote)
                && draft.text.count <= Self.maximumCharacterCount
                && hasRequiredAltText
        }
    }

    func text(for draftID: UUID) -> String {
        drafts.first { $0.id == draftID }?.text ?? ""
    }

    func mentions(for draftID: UUID) -> [String: String] {
        drafts.first { $0.id == draftID }?.mentions ?? [:]
    }

    func linkPreview(for draftID: UUID) -> TimelineExternalEmbed? {
        drafts.first { $0.id == draftID }?.linkPreview
    }

    func updateText(_ text: String, for draftID: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[index].text = text
        if externalURL(in: text) != drafts[index].externalAttachment?.uri {
            drafts[index].linkPreview = nil
            drafts[index].externalAttachment = nil
        }
    }

    func setMention(handle: String, did: String, for draftID: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[index].mentions[handle] = did
    }

    func activate(_ draftID: UUID) {
        activeDraftID = draftID
    }

    func addDraft() {
        let draft = Draft()
        drafts.append(draft)
        activeDraftID = draft.id
    }

    func addImage(data: Data, mimeType: String, altText: String = "") {
        guard let index = drafts.firstIndex(where: { $0.id == activeDraftID }) else { return }
        guard !drafts[index].attachments.contains(where: { $0.sourceURL != nil }) else {
            errorMessage = "GIFs and photos can’t be attached to the same post. Add another post or remove the GIF first."
            return
        }
        guard drafts[index].attachments.count < Self.maximumImageCount else {
            errorMessage = "You can attach up to 10 images."
            return
        }
        let image = UIImage(data: data)
        let width = max(1, Int((image?.size.width ?? 1) * (image?.scale ?? 1)))
        let height = max(1, Int((image?.size.height ?? 1) * (image?.scale ?? 1)))
        drafts[index].attachments.append(Attachment(
            data: data,
            mimeType: mimeType,
            width: width,
            height: height,
            altText: altText
        ))
        drafts[index].linkPreview = nil
        drafts[index].externalAttachment = nil
    }

    func addGIF(_ gif: KlipyGIF, previewData: Data) {
        guard let index = drafts.firstIndex(where: { $0.id == activeDraftID }) else { return }
        guard drafts[index].attachments.isEmpty else {
            errorMessage = "A GIF needs its own post. Add another post or remove the existing attachments first."
            return
        }
        guard let preview = UIImage(data: previewData),
              let thumbnailData = preview.jpegData(compressionQuality: 0.8),
              thumbnailData.count <= ComposerImageProcessor.maximumByteCount else {
            errorMessage = "The Social Wire couldn’t prepare that GIF’s preview."
            return
        }
        let width = gif.width.flatMap { $0 > 0 ? $0 : nil }
            ?? max(1, Int(preview.size.width * preview.scale))
        let height = gif.height.flatMap { $0 > 0 ? $0 : nil }
            ?? max(1, Int(preview.size.height * preview.scale))
        var resolvedGIF = gif
        resolvedGIF.width = width
        resolvedGIF.height = height
        drafts[index].attachments.append(Attachment(
            data: previewData,
            mimeType: "image/gif",
            width: width,
            height: height,
            altText: gif.description,
            sourceURL: resolvedGIF.externalURL,
            sourceTitle: gif.description.isEmpty ? gif.title : gif.description,
            thumbnailData: thumbnailData
        ))
        drafts[index].linkPreview = nil
        drafts[index].externalAttachment = nil
    }

    func remove(_ attachment: Attachment) {
        for index in drafts.indices {
            drafts[index].attachments.removeAll { $0.id == attachment.id }
        }
    }

    func moveAttachment(from sourceID: UUID, before destinationID: UUID) {
        for draftIndex in drafts.indices {
            guard let sourceIndex = drafts[draftIndex].attachments.firstIndex(where: { $0.id == sourceID }),
                  drafts[draftIndex].attachments.contains(where: { $0.id == destinationID }) else { continue }
            let attachment = drafts[draftIndex].attachments.remove(at: sourceIndex)
            guard let destinationIndex = drafts[draftIndex].attachments.firstIndex(where: { $0.id == destinationID }) else {
                drafts[draftIndex].attachments.append(attachment)
                return
            }
            drafts[draftIndex].attachments.insert(attachment, at: destinationIndex)
            return
        }
    }

    func updateAltText(_ altText: String, for attachmentID: UUID) {
        for draftIndex in drafts.indices {
            guard let attachmentIndex = drafts[draftIndex].attachments.firstIndex(where: { $0.id == attachmentID }) else {
                continue
            }
            drafts[draftIndex].attachments[attachmentIndex].altText = altText
            return
        }
    }

    func resolveLinkPreview(for draftID: UUID, using resolver: AppServices.LinkPreviewResolver) async {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }),
              drafts[index].attachments.isEmpty,
              let url = externalURL(in: drafts[index].text) else {
            return
        }
        if drafts[index].externalAttachment?.uri == url { return }

        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled,
              let preview = await resolver(url),
              let currentIndex = drafts.firstIndex(where: { $0.id == draftID }),
              drafts[currentIndex].attachments.isEmpty,
              externalURL(in: drafts[currentIndex].text) == url else { return }
        drafts[currentIndex].linkPreview = preview.embed
        drafts[currentIndex].externalAttachment = preview.attachment
    }

    func send(using source: any PostActionSource, requiringAltText: Bool = false) async {
        guard canPost(requiringAltText: requiringAltText), !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            switch context {
            case .post:
                try await source.createThread(threadDrafts)
            case .reply(let post):
                try await source.createReplyThread(threadDrafts, to: post)
            case .quote(let post):
                try await source.createQuoteThread(threadDrafts, quoting: post)
            }
            didPost = true
        } catch let failure as PostThreadPublicationFailure {
            preserveUnpublishedDrafts(after: failure)
        } catch {
            errorMessage = "The Social Wire couldn’t publish this post. \(error.localizedDescription)"
        }
    }

    private func preserveUnpublishedDrafts(after failure: PostThreadPublicationFailure) {
        let confirmedCount = min(failure.publishedCount, drafts.count)
        if confirmedCount > 0,
           let rootURI = failure.rootURI, let rootCID = failure.rootCID,
           let parentURI = failure.parentURI, let parentCID = failure.parentCID {
            let lastPublished = drafts[confirmedCount - 1]
            let authorDID = parentURI.components(separatedBy: "/").dropFirst(2).first ?? ""
            context = .reply(TimelinePost(
                uri: parentURI, cid: parentCID,
                author: TimelineAuthor(did: authorDID, handle: authorDID),
                text: lastPublished.text, createdAt: Date(),
                replyRootURI: rootURI, replyRootCID: rootCID
            ))
            drafts.removeFirst(confirmedCount)
            if !drafts.contains(where: { $0.id == activeDraftID }), let first = drafts.first {
                activeDraftID = first.id
            }
        }
        hasUncertainPublication = failure.currentDraftOutcomeUncertain
        if hasUncertainPublication {
            errorMessage = "The last post may have published. Check your profile before posting again. Your remaining drafts are preserved here."
        } else {
            errorMessage = "\(confirmedCount) post(s) published. Your remaining drafts are ready to retry. \(failure.localizedDescription)"
        }
    }

    var threadDrafts: [PostThreadDraft] {
        drafts.map { draft in
            let gif = draft.attachments.first { $0.sourceURL != nil }
            let external: PostExternalAttachment?
            if let gif, let uri = gif.sourceURL {
                external = PostExternalAttachment(
                    uri: uri,
                    title: gif.sourceTitle,
                    description: (gif.altText == gif.sourceTitle ? "ALT: " : "Alt: ") + gif.altText,
                    thumbnailData: gif.thumbnailData,
                    thumbnailMimeType: gif.thumbnailData == nil ? nil : "image/jpeg"
                )
            } else {
                external = draft.attachments.isEmpty ? draft.externalAttachment : nil
            }
            return PostThreadDraft(
                text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                mentions: draft.mentions,
                images: draft.attachments.filter { $0.sourceURL == nil }.map {
                    PostImageAttachment(
                        data: $0.data,
                        mimeType: $0.mimeType,
                        altText: $0.altText,
                        width: $0.width,
                        height: $0.height
                    )
                },
                external: external
            )
        }
    }

    private func externalURL(in text: String) -> URL? {
        guard let expression = try? NSRegularExpression(pattern: #"https?:\/\/[^\s<>`]+"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let value = text[range].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
        return URL(string: value)
    }
}

#endif
