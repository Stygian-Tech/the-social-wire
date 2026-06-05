import Foundation

enum SavedLinkSocialTarget {
    private static let originalEntryCollections: Set<String> = [
        "site.standard.document",
        "com.standard.document",
        "site.standard.entry",
        "com.standard.entry",
    ]

    static func originalEntryId(from save: MergedLatrSave) -> String? {
        guard case .native(let native) = save else { return nil }
        guard let parsed = ATURI(native.subjectUri) else { return nil }
        guard originalEntryCollections.contains(parsed.collection) else { return nil }
        return native.subjectUri
    }

    static func fallbackEntryDetail(from save: MergedLatrSave) -> EntryDetail? {
        guard let url = SavedLinkEmbedURL.resolveEmbedURL(for: save) else { return nil }
        let normalized = PublicURLNormalizer.normalizeHttpURLToHTTPS(url)
        let entryId = originalEntryId(from: save) ?? "saved-link:external"
        return EntryDetail(
            entryId: entryId,
            title: save.title,
            publishedAt: save.publishedAt ?? save.savedAt,
            contentHtml: "",
            originalUrl: normalized,
            embedUrl: normalized,
            bskyPostUri: nil,
            bskyPostCid: nil
        )
    }
}
