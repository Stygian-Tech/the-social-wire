import Foundation

enum NewsTabSlot: Hashable {
    case wire
    case circle
    case finance
    case podcasts
    case sports
    case subscribed
    case following
    case standardList(String)
    case readLater
    case archive

    init(_ feed: NewsPrimaryFeed) {
        switch feed {
        case .wire: self = .wire
        case .circle: self = .circle
        case .finance: self = .finance
        case .podcasts: self = .podcasts
        case .sports: self = .sports
        case .subscribed: self = .subscribed
        case .following: self = .following
        }
    }

    var primaryFeed: NewsPrimaryFeed? {
        switch self {
        case .wire: .wire
        case .circle: .circle
        case .finance: .finance
        case .podcasts: .podcasts
        case .sports: .sports
        case .subscribed: .subscribed
        case .following: .following
        case .standardList, .readLater, .archive: nil
        }
    }

    var savedListSource: ReaderListSource? {
        switch self {
        case .readLater: .readLater
        case .archive: .archive
        case .wire, .circle, .finance, .podcasts, .sports, .subscribed, .following, .standardList: nil
        }
    }
}
