#if os(iOS)
import Feeds
import Foundation
import Observation

@MainActor
@Observable
final class PostActionsModel {
    let post: TimelinePost
    var isReplyPresented = false
    var replyText = ""
    var replyMentions: [String: String] = [:]
    var isQuotePresented = false
    var quoteText = ""
    var quoteMentions: [String: String] = [:]
    var isTranslationPresented = false
    private(set) var likeCount: Int
    private(set) var repostCount: Int
    private(set) var quoteCount: Int
    private(set) var likeURI: String?
    private(set) var repostURI: String?
    private(set) var hasQuoted = false
    private(set) var isUpdatingLike = false
    private(set) var isUpdatingRepost = false
    private(set) var isSendingReply = false
    private(set) var isSendingQuote = false
    private(set) var feedbackGeneration = 0
    private(set) var errorGeneration = 0

    init(post: TimelinePost) {
        self.post = post
        likeCount = post.likeCount
        repostCount = post.repostCount
        quoteCount = post.quoteCount
        likeURI = post.viewerLikeURI
        repostURI = post.viewerRepostURI
    }

    var repostAndQuoteCount: Int {
        repostCount + quoteCount
    }

    var hasRepostedOrQuoted: Bool {
        repostURI != nil || hasQuoted
    }

    func toggleLike(using source: any PostActionSource) async {
        guard !isUpdatingLike else { return }
        isUpdatingLike = true
        let previousURI = likeURI
        likeURI = previousURI == nil ? "pending" : nil
        likeCount = max(0, likeCount + (previousURI == nil ? 1 : -1))
        defer { isUpdatingLike = false }

        do {
            if let previousURI {
                try await source.unlike(recordURI: previousURI)
            } else {
                likeURI = try await source.like(post)
            }
            feedbackGeneration += 1
        } catch {
            likeURI = previousURI
            likeCount = max(0, likeCount + (previousURI == nil ? -1 : 1))
            errorGeneration += 1
        }
    }

    func toggleRepost(using source: any PostActionSource) async {
        guard !isUpdatingRepost else { return }
        isUpdatingRepost = true
        let previousURI = repostURI
        repostURI = previousURI == nil ? "pending" : nil
        repostCount = max(0, repostCount + (previousURI == nil ? 1 : -1))
        defer { isUpdatingRepost = false }

        do {
            if let previousURI {
                try await source.undoRepost(recordURI: previousURI)
            } else {
                repostURI = try await source.repost(post)
            }
            feedbackGeneration += 1
        } catch {
            repostURI = previousURI
            repostCount = max(0, repostCount + (previousURI == nil ? -1 : 1))
            errorGeneration += 1
        }
    }

    func sendReply(using source: any PostActionSource) async {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingReply else { return }
        isSendingReply = true
        defer { isSendingReply = false }

        do {
            try await source.reply(text: text, mentions: replyMentions, to: post)
            replyText = ""
            replyMentions = [:]
            isReplyPresented = false
            feedbackGeneration += 1
        } catch {
            errorGeneration += 1
        }
    }

    func sendQuote(using source: any PostActionSource) async {
        guard !isSendingQuote else { return }
        isSendingQuote = true
        defer { isSendingQuote = false }

        do {
            try await source.quote(
                text: quoteText.trimmingCharacters(in: .whitespacesAndNewlines),
                mentions: quoteMentions,
                post: post
            )
            quoteCount += 1
            hasQuoted = true
            quoteText = ""
            quoteMentions = [:]
            isQuotePresented = false
            feedbackGeneration += 1
        } catch {
            errorGeneration += 1
        }
    }

    func didPublishReply() {
        isReplyPresented = false
        feedbackGeneration += 1
    }

    func didPublishQuote() {
        quoteCount += 1
        hasQuoted = true
        isQuotePresented = false
        feedbackGeneration += 1
    }
}

#endif
