import Foundation

/// Top-level list bucket on the reader's Lists pane.
enum ReaderListSource: String, CaseIterable, Codable, Identifiable, Hashable {
    case wire = "The Wire"
    case readLater = "Read Later"
    case archive = "Archive"
    case subscribed = "Subscribed"
    case following = "Following"

    var id: String { rawValue }

    var preferenceKey: String {
        switch self {
        case .wire: "wire"
        case .readLater: "readLater"
        case .archive: "archive"
        case .subscribed: "subscribed"
        case .following: "following"
        }
    }

    init?(preferenceKey: String) {
        switch preferenceKey {
        case "wire": self = .wire
        case "readLater": self = .readLater
        case "archive": self = .archive
        case "subscribed": self = .subscribed
        case "following": self = .following
        default: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .wire: "dot.radiowaves.left.and.right"
        case .readLater: "bookmark"
        case .archive: "archivebox"
        case .subscribed: "tray.full"
        case .following: "person.2"
        }
    }

    var supportsReadState: Bool {
        switch self {
        case .wire, .readLater, .archive: false
        case .subscribed, .following: true
        }
    }

    var navigationSubtitle: String? {
        self == .wire ? "Important stories across the social web" : nil
    }

    /// Feed-display preferences predate The Wire. Keep the server-gated feed outside the
    /// shared PDS preference so older clients cannot erase it when rewriting that record.
    static let preferenceCases: [ReaderListSource] = [
        .readLater, .archive, .subscribed, .following,
    ]

    var supportsMarkAllReadContextMenu: Bool {
        switch self {
        case .wire: false
        case .subscribed, .following: true
        case .readLater, .archive: false
        }
    }
}
