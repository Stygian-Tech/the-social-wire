import Foundation

enum SocialDestination: String, CaseIterable, Codable, Identifiable, Sendable {
    case timeline
    case explore
    case feeds
    case notifications
    case messages
    case bookmarks
    case lists
    case proTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: "Timeline"
        case .explore: "Explore"
        case .feeds: "Feeds"
        case .notifications: "Notifications"
        case .messages: "Messages"
        case .bookmarks: "Bookmarks"
        case .lists: "Lists"
        case .proTools: "Pro Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline: "bubble.left.and.text.bubble.right"
        case .explore: "magnifyingglass"
        case .feeds: "rectangle.stack"
        case .notifications: "bell"
        case .messages: "message"
        case .bookmarks: "bookmark"
        case .lists: "list.bullet"
        case .proTools: "lock"
        }
    }

    var requiresPro: Bool { self == .proTools }
}
