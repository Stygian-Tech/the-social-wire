import Foundation

struct SembleCardRecord: Codable, Equatable, Sendable {
    let type: String
    let cardType: String
    let content: SembleCardContent
    let url: String?
    let parentCard: StrongRef?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case cardType = "type"
        case content
        case url
        case parentCard
        case createdAt
    }

    static func url(_ url: String, createdAt: String) -> Self {
        Self(
            type: SembleRecordCollection.card,
            cardType: "URL",
            content: .url(SembleURLCardContent(type: "network.cosmik.card#urlContent", url: url)),
            url: url,
            parentCard: nil,
            createdAt: createdAt
        )
    }

    static func note(_ text: String, parentCard: StrongRef, createdAt: String) -> Self {
        Self(
            type: SembleRecordCollection.card,
            cardType: "NOTE",
            content: .note(SembleNoteCardContent(type: "network.cosmik.card#noteContent", text: text)),
            url: nil,
            parentCard: parentCard,
            createdAt: createdAt
        )
    }
}

enum SembleCardContent: Codable, Equatable, Sendable {
    case url(SembleURLCardContent)
    case note(SembleNoteCardContent)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let url = try? container.decode(SembleURLCardContent.self), url.type.hasSuffix("#urlContent") {
            self = .url(url)
        } else {
            self = .note(try container.decode(SembleNoteCardContent.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .url(let value): try container.encode(value)
        case .note(let value): try container.encode(value)
        }
    }
}

struct SembleURLCardContent: Codable, Equatable, Sendable {
    let type: String
    let url: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case url
    }
}

struct SembleNoteCardContent: Codable, Equatable, Sendable {
    let type: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case text
    }
}
