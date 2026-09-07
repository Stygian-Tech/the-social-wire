import Foundation

enum EntryOpenTarget: Equatable, Sendable {
    case external(URL)
    case nativeRSS(URL)
}

enum EntryOpenTargetResolver {
    static let rssEntryPrefix = "rssentry:"

    static func resolve(
        entryId: String,
        originalURL: String?,
        rssArticleOpenMode: ArticleOpenMode
    ) -> EntryOpenTarget? {
        guard let url = validatedWebsiteURL(originalURL) else { return nil }

        if isRSSEntry(entryId), rssArticleOpenMode == .reader {
            return .nativeRSS(url)
        }
        return .external(url)
    }

    static func isRSSEntry(_ entryId: String) -> Bool {
        entryId.hasPrefix(rssEntryPrefix)
    }

    private static func validatedWebsiteURL(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let suppliedScheme = URL(string: trimmed)?.scheme?.lowercased(),
           suppliedScheme != "http",
           suppliedScheme != "https" {
            return nil
        }

        let normalized = PublicURLNormalizer.normalizeHttpURLToHTTPS(trimmed)
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url
    }
}
