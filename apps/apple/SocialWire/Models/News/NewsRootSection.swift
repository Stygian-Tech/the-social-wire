import Foundation

enum NewsRootSection: String, CaseIterable, Codable, Identifiable, Hashable {
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .readLater: "Read Later"
        case .feeds: "News"
        case .topics: "Topics"
        case .lists: "Lists"
        case .social: "Social"
        case .media: "Media"
        }
    }

    case readLater
    case feeds
    case topics
    case lists
    case social
    case media

    var systemImage: String {
        switch self {
        case .readLater: "bookmark"
        case .feeds: "newspaper"
        case .topics: "square.grid.2x2"
        case .lists: "list.bullet"
        case .social: "bubble.left.and.text.bubble.right"
        case .media: "play.rectangle"
        }
    }

    var fallbackSlot: NewsTabSlot {
        switch self {
        case .readLater: .readLater
        case .feeds: .wire
        case .topics: .finance
        case .lists: .standardList("")
        case .social: .wire
        case .media: .podcasts
        }
    }

    var emptyTitle: LocalizedStringResource {
        switch self {
        case .readLater: "Nothing Saved"
        case .feeds: "No Feeds"
        case .topics: "No Topics"
        case .lists: "No Lists"
        case .social: "Social Unavailable"
        case .media: "No Media"
        }
    }

    var emptyDescription: LocalizedStringResource {
        switch self {
        case .readLater: "Saved articles will appear here."
        case .feeds: "Available feeds will appear here."
        case .topics: "Available topics will appear here."
        case .lists: "Your reader lists will appear here."
        case .social: "Your social workspace will appear here."
        case .media: "Available podcasts will appear here."
        }
    }
}
