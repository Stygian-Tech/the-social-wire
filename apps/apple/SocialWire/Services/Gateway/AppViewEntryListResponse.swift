import Foundation

struct AppViewEntryListResponse: Codable, Sendable {
    let entries: [EntryListItem]
    let cursor: String?
}

/// Flat AppView `GET /v1/appview/entry` payload (matches `AppViewEntryDetailResponse` on the server).
struct AppViewEntryDetailDTO: Decodable, Sendable {
    let entryId: String
    let title: String
    let summary: String?
    let publishedAt: String
    let thumbnailUrl: String?
    let isRead: Bool?
    let contentHtml: String?
    let originalUrl: String?

    enum CodingKeys: String, CodingKey {
        case entryId
        case title
        case summary
        case publishedAt
        case thumbnailUrl
        case isRead
        case contentHtml
        case originalUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryId = try container.decode(String.self, forKey: .entryId)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead)
        contentHtml = try container.decodeIfPresent(String.self, forKey: .contentHtml)
        originalUrl = try container.decodeIfPresent(String.self, forKey: .originalUrl)

        if let published = try? container.decode(String.self, forKey: .publishedAt) {
            publishedAt = published
        } else {
            let dateDecoder = JSONDecoder()
            dateDecoder.dateDecodingStrategy = .iso8601
            let raw = try container.decode(Date.self, forKey: .publishedAt)
            publishedAt = DateFormatters.string(from: raw)
        }
    }

    func toEntryDetail() -> EntryDetail {
        let normalizedOriginal = originalUrl.map { PublicURLNormalizer.normalizeHttpURLToHTTPS($0) }
        return EntryDetail(
            entryId: entryId,
            title: title,
            publishedAt: publishedAt,
            contentHtml: contentHtml ?? summary ?? "",
            originalUrl: normalizedOriginal,
            embedUrl: normalizedOriginal,
            bskyPostUri: nil,
            bskyPostCid: nil
        )
    }
}

struct AppViewUnreadCountsResponse: Codable, Sendable {
    let counts: [String: Int]?
}
