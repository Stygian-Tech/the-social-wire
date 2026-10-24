import Foundation

struct SocialPost: Hashable, Identifiable, Sendable {
    var id: String { uri }
    let uri: String
    let cid: String
    let author: SocialAuthor
    let text: String
    let createdAt: Date
    var replyCount: Int
    var repostCount: Int
    var likeCount: Int
    var quoteCount: Int
    var viewerLikeURI: String?
    var viewerRepostURI: String?
    let replyRoot: SocialPostReference?
    let replyParent: SocialPostReference?
    let replyingTo: SocialAuthor?
    let repostedBy: SocialAuthor?
    let embed: SocialEmbed
    let labels: [String]
}
