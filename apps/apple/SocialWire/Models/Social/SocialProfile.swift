import Foundation

struct SocialProfile: Hashable, Identifiable, Sendable {
    var id: String { author.did }
    let author: SocialAuthor
    let description: String
    let banner: URL?
    let followersCount: Int
    let followsCount: Int
    let postsCount: Int
    let followsViewer: Bool
    var viewerFollowingURI: String?
    let viewerMuted: Bool
    let viewerBlockedBy: Bool
    var viewerBlockingURI: String?
}
