import Foundation

struct SocialConversation: Hashable, Identifiable, Sendable {
    let id: String
    let members: [SocialAuthor]
    let lastMessage: SocialMessage?
    var unreadCount: Int
    let muted: Bool
    let status: String?
}

struct SocialMessage: Hashable, Identifiable, Sendable {
    let id: String
    let revision: String?
    let senderDID: String
    let text: String
    let sentAt: Date
    let replyTo: SocialMessageReference?
    let reactions: [SocialMessageReaction]
}

struct SocialMessageReference: Hashable, Sendable {
    let id: String
    let revision: String?
}

struct SocialMessageReaction: Hashable, Identifiable, Sendable {
    var id: String { "\(senderDID)|\(value)" }
    let senderDID: String
    let value: String
    let createdAt: Date?
}
