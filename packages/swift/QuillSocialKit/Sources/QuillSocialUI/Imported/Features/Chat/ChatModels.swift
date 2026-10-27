#if os(iOS)
import Foundation

enum ChatModels {
    struct Profile: Decodable, Identifiable, Sendable {
        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?

        var id: String { did }
    }

    struct Sender: Decodable, Sendable {
        let did: String
    }

    struct Reaction: Decodable, Identifiable, Sendable {
        let value: String
        let sender: Sender
        let createdAt: Date

        var id: String { "\(sender.did):\(value)" }
    }

    struct ReplyPreview: Decodable, Sendable {
        let id: String?
        let text: String?
        let sender: Sender?

        private enum CodingKeys: String, CodingKey {
            case id, text, sender
        }
    }

    struct Facet: Decodable, Sendable {
        struct Index: Decodable, Sendable {
            let byteStart: Int
            let byteEnd: Int
        }
        struct Feature: Decodable, Sendable {
            let type: String
            let did: String?
            let uri: String?
            private enum CodingKeys: String, CodingKey {
                case type = "$type", did, uri
            }
        }
        let index: Index
        let features: [Feature]
    }

    struct Message: Decodable, Identifiable, Sendable {
        let id: String
        let rev: String
        let text: String?
        let sender: Sender?
        let sentAt: Date
        let reactions: [Reaction]
        let replyTo: ReplyPreview?
        let facets: [Facet]

        private enum CodingKeys: String, CodingKey {
            case id, rev, text, sender, sentAt, reactions, replyTo, facets
        }

        var gifURL: URL? {
            linkURLs
                .first { $0.pathExtension.lowercased() == "gif" }
        }

        var linkURLs: [URL] {
            guard let text else { return [] }
            return ChatLinkDetector.matches(in: text).map(\.url)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            rev = try container.decode(String.self, forKey: .rev)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            sender = try container.decodeIfPresent(Sender.self, forKey: .sender)
            sentAt = try container.decode(Date.self, forKey: .sentAt)
            reactions = try container.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
            replyTo = try? container.decodeIfPresent(ReplyPreview.self, forKey: .replyTo)
            facets = (try? container.decodeIfPresent([Facet].self, forKey: .facets)) ?? []
        }
    }

    struct ConversationPreview: Decodable, Sendable {
        let text: String?
        let sentAt: Date?
        let isDeleted: Bool
        let hasEmbed: Bool

        private enum CodingKeys: String, CodingKey {
            case type = "$type"
            case text, sentAt, embed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt)
            let type = try container.decodeIfPresent(String.self, forKey: .type)
            isDeleted = type?.contains("deletedMessageView") == true
            hasEmbed = container.contains(.embed)
        }

        var summary: String {
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if isDeleted { return "Message deleted" }
            if hasEmbed { return "Attachment" }
            return "Message"
        }
    }

    struct Conversation: Decodable, Identifiable, Sendable {
        struct Kind: Decodable, Sendable {
            let name: String?
            let memberCount: Int?
            let lockStatus: String?
        }

        let id: String
        let rev: String
        let members: [Profile]
        let lastMessage: ConversationPreview?
        let muted: Bool
        let status: String?
        let unreadCount: Int
        let kind: Kind?

        private enum CodingKeys: String, CodingKey {
            case id, rev, members, lastMessage, muted, status, unreadCount, kind
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            rev = try container.decode(String.self, forKey: .rev)
            members = try container.decode([Profile].self, forKey: .members)
            lastMessage = try? container.decodeIfPresent(ConversationPreview.self, forKey: .lastMessage)
            muted = try container.decode(Bool.self, forKey: .muted)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            unreadCount = try container.decode(Int.self, forKey: .unreadCount)
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
        }

        func title(currentDID: String) -> String {
            if let name = kind?.name, !name.isEmpty { return name }
            let others = members.filter { $0.did != currentDID }
            return others.map { $0.displayName ?? $0.handle }.joined(separator: ", ")
        }

        func avatar(currentDID: String) -> URL? {
            members.first { $0.did != currentDID }?.avatar
        }
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(value, strategy: .iso8601) { return date }
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
        }
        return decoder
    }
}

#endif
