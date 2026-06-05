import Foundation

enum ArticlePresentationMode: Equatable, Sendable {
    case html
    case webPreview
}

enum ArticlePresentationResolver {
    static func isSubstantialArticleBody(_ html: String) -> Bool {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count >= 600 { return true }
        let textOnly = trimmed
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return textOnly.count >= 280
    }

    static func resolve(
        contentHtml: String,
        embedUrl: String?,
        originalUrl: String?
    ) -> ArticlePresentationMode? {
        if isSubstantialArticleBody(contentHtml) {
            return .html
        }
        let embedTarget = embedUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? originalUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let embedTarget, !embedTarget.isEmpty, !SavedLinkEmbedURL.isPoorIframeEmbedTarget(embedTarget) {
            return .webPreview
        }
        if let embedTarget, !embedTarget.isEmpty, !contentHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .html
        }
        if !contentHtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .html
        }
        if let embedTarget, !embedTarget.isEmpty {
            return .webPreview
        }
        return nil
    }

    nonisolated(unsafe) private static var lockedPresentationByEntryId: [String: ArticlePresentationMode?] = [:]

    static func lockedPresentation(
        entryId: String,
        contentHtml: String,
        embedUrl: String?,
        originalUrl: String?
    ) -> ArticlePresentationMode? {
        if lockedPresentationByEntryId.keys.contains(entryId) {
            return lockedPresentationByEntryId[entryId] ?? nil
        }
        let mode = resolve(contentHtml: contentHtml, embedUrl: embedUrl, originalUrl: originalUrl)
        lockedPresentationByEntryId[entryId] = mode
        return mode
    }

    #if DEBUG
    static func clearLockedPresentationsForTests() {
        lockedPresentationByEntryId.removeAll()
    }
    #endif
}
