#if os(iOS)
import Navigation
import SwiftUI

extension Route {
    var title: LocalizedStringResource {
        switch self {
        case .thread: "Post"
        case .profile: "Profile"
        case .feed: "Feed"
        case .list: "List"
        case let .hashtag(tag): "#\(tag)"
        case .conversation: "Chat"
        case .likedBy: "Liked By"
        case .repostedBy: "Reposted By"
        case .quotes: "Quotes"
        case .followers: "Followers"
        case .following: "Following"
        case .labeler: "Labeler"
        case .settings: "Settings"
        }
    }
}

#endif
