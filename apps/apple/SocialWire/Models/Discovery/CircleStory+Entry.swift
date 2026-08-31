import Foundation

extension CircleStory {
    func toEntryListItem() -> EntryListItem {
        EntryListItem(
            entryId: storyId,
            title: title,
            summary: summary,
            publishedAt: publishedAt ?? "",
            thumbnailUrl: thumbnailUrl,
            thumbnailFallbackUrl: PublicationSiteFavicon.url(for: source.domain),
            originalUrl: canonicalUrl,
            publicationId: nil,
            isRead: false,
            wireMetadata: WireEntryMetadata(
                source: source,
                reasons: reasons,
                provenance: [],
                representativeUri: representativeUri
            )
        )
    }

    func toEntryDetail() -> EntryDetail {
        let normalizedURL = PublicURLNormalizer.normalizeHttpURLToHTTPS(canonicalUrl)
        return EntryDetail(
            entryId: representativeUri ?? storyId,
            title: title,
            publishedAt: publishedAt ?? "",
            contentHtml: summary ?? "",
            originalUrl: normalizedURL,
            embedUrl: normalizedURL,
            bskyPostUri: nil,
            bskyPostCid: nil
        )
    }
}
