import Foundation

/// Top-level list bucket on the compact lists pane (Read Later / Archive / Subscribed / Following).
enum ReaderListSource: String, CaseIterable, Codable, Identifiable, Hashable {
    case readLater = "Read Later"
    case archive = "Archive"
    case subscribed = "Subscribed"
    case following = "Following"

    var id: String { rawValue }

    var preferenceKey: String {
        switch self {
        case .readLater: "readLater"
        case .archive: "archive"
        case .subscribed: "subscribed"
        case .following: "following"
        }
    }

    init?(preferenceKey: String) {
        switch preferenceKey {
        case "readLater": self = .readLater
        case "archive": self = .archive
        case "subscribed": self = .subscribed
        case "following": self = .following
        default: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .readLater: "bookmark"
        case .archive: "archivebox"
        case .subscribed: "tray.full"
        case .following: "person.2"
        }
    }

    /// Subscribed/Following use a four-pane compact pager (lists → publications → articles → reader).
    /// Read Later/Archive use three panes (lists → saved links → reader).
    var compactUsesArticlesPane: Bool {
        switch self {
        case .readLater, .archive: false
        case .subscribed, .following: true
        }
    }

    var supportsMarkAllReadContextMenu: Bool {
        switch self {
        case .subscribed, .following: true
        case .readLater, .archive: false
        }
    }
}
