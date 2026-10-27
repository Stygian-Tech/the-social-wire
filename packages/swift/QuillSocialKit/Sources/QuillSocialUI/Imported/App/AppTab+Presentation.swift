#if os(iOS)
import Navigation
import SwiftUI

extension AppTab {
    /// `LocalizedStringResource` rather than `String`, so the text stays localizable all the
    /// way to the view that displays it.
    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .search: "Explore"
        case .notifications: "Notifications"
        case .chat: "Chat"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .search: "safari"
        case .notifications: "bell"
        case .chat: "bubble.left.and.bubble.right"
        case .profile: "person.crop.circle"
        }
    }


    var emptyStateTitle: LocalizedStringResource {
        switch self {
        case .home: "No Posts Yet"
        case .search: "Explore Bluesky"
        case .notifications: "No Notifications"
        case .chat: "No Conversations"
        case .profile: "Your Profile"
        }
    }

    var emptyStateDescription: LocalizedStringResource {
        switch self {
        case .home: "Posts from the people and feeds you follow will appear here."
        case .search: "Find people, follow trends, and discover new feeds."
        case .notifications: "Likes, reposts, replies, and new followers will appear here."
        case .chat: "Conversations you start or receive will appear here."
        case .profile: "Your posts, replies, and likes will appear here."
        }
    }
}

#endif
