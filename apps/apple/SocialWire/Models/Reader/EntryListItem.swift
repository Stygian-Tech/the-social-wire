import Foundation

struct EntryListItem: Identifiable, Codable, Equatable, Sendable {
    var entryId: String
    var title: String
    var summary: String?
    var publishedAt: String
    var formattedPublishedAt: String?
    var thumbnailUrl: String?
    var thumbnailFallbackUrl: String?
    var originalUrl: String?
    var publicationId: String?
    var isRead: Bool

    var id: String { entryId }

    var displayPublishedAt: String {
        formattedPublishedAt ?? Self.formatDisplayPublishedAt(publishedAt)
    }

    init(
        entryId: String,
        title: String,
        summary: String?,
        publishedAt: String,
        formattedPublishedAt: String? = nil,
        thumbnailUrl: String?,
        thumbnailFallbackUrl: String?,
        originalUrl: String? = nil,
        publicationId: String? = nil,
        isRead: Bool = false
    ) {
        self.entryId = entryId
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.formattedPublishedAt = formattedPublishedAt ?? Self.formatDisplayPublishedAt(publishedAt)
        self.thumbnailUrl = thumbnailUrl
        self.thumbnailFallbackUrl = thumbnailFallbackUrl
        self.originalUrl = originalUrl
        self.publicationId = publicationId
        self.isRead = isRead
    }

    enum CodingKeys: String, CodingKey {
        case entryId
        case title
        case summary
        case publishedAt
        case formattedPublishedAt
        case thumbnailUrl
        case thumbnailFallbackUrl
        case originalUrl
        case publicationId
        case isRead
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryId = try container.decode(String.self, forKey: .entryId)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        publishedAt = try container.decode(String.self, forKey: .publishedAt)
        formattedPublishedAt = try container.decodeIfPresent(String.self, forKey: .formattedPublishedAt)
            ?? Self.formatDisplayPublishedAt(publishedAt)
        thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        thumbnailFallbackUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailFallbackUrl)
        originalUrl = try container.decodeIfPresent(String.self, forKey: .originalUrl)
        publicationId = try container.decodeIfPresent(String.self, forKey: .publicationId)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryId, forKey: .entryId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(publishedAt, forKey: .publishedAt)
        try container.encode(displayPublishedAt, forKey: .formattedPublishedAt)
        try container.encodeIfPresent(thumbnailUrl, forKey: .thumbnailUrl)
        try container.encodeIfPresent(thumbnailFallbackUrl, forKey: .thumbnailFallbackUrl)
        try container.encodeIfPresent(originalUrl, forKey: .originalUrl)
        try container.encodeIfPresent(publicationId, forKey: .publicationId)
        try container.encode(isRead, forKey: .isRead)
    }

    static func formatDisplayPublishedAt(_ raw: String) -> String {
        EntryDisplayDate.listRowPublishedAt(raw)
    }
}
