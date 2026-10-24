import Foundation

struct SocialNotification: Hashable, Identifiable, Sendable {
    var id: String { "\(uri)|\(reason)|\(author.did)" }
    let uri: String
    let cid: String
    let author: SocialAuthor
    let reason: String
    let reasonSubject: String?
    let indexedAt: Date
    var isRead: Bool
    let post: SocialPost?
}
