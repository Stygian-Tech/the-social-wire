import Foundation

enum NewsPrimaryFeed: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case wire
    case circle
    case subscribed
    case following

    var id: Self { self }

    var title: String {
        switch self {
        case .wire: "The Wire"
        case .circle: "Your Circle"
        case .subscribed: "Subscribed"
        case .following: "Following"
        }
    }

    var systemImage: String {
        switch self {
        case .wire: "newspaper"
        case .circle: "person.2.wave.2"
        case .subscribed: "tray.full"
        case .following: "person.2"
        }
    }

    var newsTab: NewsTab {
        switch self {
        case .wire: .wire
        case .circle: .circle
        case .subscribed, .following: .library
        }
    }

    var readerListSource: ReaderListSource? {
        switch self {
        case .wire: .wire
        case .circle: nil
        case .subscribed: .subscribed
        case .following: .following
        }
    }

    static let defaultFeeds: [Self] = [.wire, .circle, .subscribed, .following]
}
