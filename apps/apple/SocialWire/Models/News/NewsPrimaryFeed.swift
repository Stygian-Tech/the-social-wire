import Foundation

enum NewsPrimaryFeed: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case wire
    case circle
    case finance
    case podcasts
    case sports
    case subscribed
    case following

    var id: Self { self }

    var title: String {
        switch self {
        case .wire: "The Wire"
        case .circle: "Your Circle"
        case .finance: "Finance"
        case .podcasts: "Podcasts"
        case .sports: "Sports"
        case .subscribed: "Subscribed"
        case .following: "Following"
        }
    }

    var systemImage: String {
        switch self {
        case .wire: "newspaper"
        case .circle: "person.2.wave.2"
        case .finance: "chart.line.uptrend.xyaxis"
        case .podcasts: "headphones"
        case .sports: "sportscourt"
        case .subscribed: "tray.full"
        case .following: "person.2"
        }
    }

    var newsTab: NewsTab {
        switch self {
        case .wire: .wire
        case .circle: .circle
        case .finance: .finance
        case .podcasts: .podcasts
        case .sports: .sports
        case .subscribed, .following: .library
        }
    }

    var readerListSource: ReaderListSource? {
        switch self {
        case .wire: .wire
        case .circle, .finance, .sports, .podcasts: nil
        case .subscribed: .subscribed
        case .following: .following
        }
    }

    static let defaultFeeds: [Self] = [.wire, .circle, .subscribed, .following]
}
