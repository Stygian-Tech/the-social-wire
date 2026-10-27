import Foundation

struct SocialFeedSummary: Hashable, Identifiable, Sendable {
    var id: String { uri }
    let uri: String
    let cid: String
    let did: String
    let creator: SocialAuthor
    let displayName: String
    let description: String
    let avatar: URL?
    let likeCount: Int
}
