import Foundation

struct WireFeedItem: Codable, Equatable, Sendable {
    let itemId: String
    let canonicalUrl: String
    let representativeUri: String?
    let representativeCid: String?
    let title: String
    let summary: String?
    let publishedAt: String?
    let thumbnailUrl: String?
    let source: WireFeedSource
    let reasons: [String]
    let provenance: [String]
    let html: String?
    let embedUrl: String?

    private enum CodingKeys: String, CodingKey {
        case itemId
        case canonicalUrl
        case representativeUri
        case representativeCid
        case title
        case summary
        case publishedAt
        case thumbnailUrl
        case source
        case reasons
        case provenance
        case html
        case embedUrl
    }

    init(
        itemId: String,
        canonicalUrl: String,
        representativeUri: String?,
        representativeCid: String? = nil,
        title: String,
        summary: String?,
        publishedAt: String?,
        thumbnailUrl: String?,
        source: WireFeedSource,
        reasons: [String],
        provenance: [String],
        html: String? = nil,
        embedUrl: String? = nil
    ) {
        self.itemId = itemId
        self.canonicalUrl = canonicalUrl
        self.representativeUri = representativeUri
        self.representativeCid = representativeCid
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.thumbnailUrl = thumbnailUrl
        self.source = source
        self.reasons = Array(reasons.prefix(2))
        self.provenance = provenance
        self.html = html
        self.embedUrl = embedUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decode(String.self, forKey: .itemId)
        canonicalUrl = try container.decode(String.self, forKey: .canonicalUrl)
        representativeUri = try container.decodeIfPresent(String.self, forKey: .representativeUri)
        representativeCid = try container.decodeIfPresent(String.self, forKey: .representativeCid)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        source = try container.decode(WireFeedSource.self, forKey: .source)
        reasons = Array((try container.decodeIfPresent([String].self, forKey: .reasons) ?? []).prefix(2))
        provenance = try container.decodeIfPresent([String].self, forKey: .provenance) ?? []
        html = try container.decodeIfPresent(String.self, forKey: .html)
        embedUrl = try container.decodeIfPresent(String.self, forKey: .embedUrl)
    }

    func toEntryListItem() -> EntryListItem {
        EntryListItem(
            entryId: itemId,
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
                provenance: provenance,
                representativeUri: representativeUri
            )
        )
    }

    func toEntryDetail(
        html presentationHTML: String? = nil,
        embedUrl presentationEmbedURL: String? = nil
    ) -> EntryDetail {
        let normalizedCanonical = PublicURLNormalizer.normalizeHttpURLToHTTPS(canonicalUrl)
        let validStrongRef = representativeUri != nil && representativeCid != nil
        return EntryDetail(
            entryId: itemId,
            title: title,
            publishedAt: publishedAt ?? "",
            contentHtml: presentationHTML ?? html ?? summary ?? "",
            originalUrl: normalizedCanonical,
            embedUrl: (presentationEmbedURL ?? embedUrl)
                .map(PublicURLNormalizer.normalizeHttpURLToHTTPS) ?? normalizedCanonical,
            bskyPostUri: validStrongRef ? representativeUri : nil,
            bskyPostCid: validStrongRef ? representativeCid : nil
        )
    }
}
