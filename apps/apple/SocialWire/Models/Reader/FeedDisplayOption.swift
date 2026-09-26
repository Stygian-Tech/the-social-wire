import Foundation

enum FeedDisplayOption: String, CaseIterable, Identifiable, Sendable {
    case showFeedAndCount
    case showFeedOnly
    case hideFeed

    var id: Self { self }

    var title: String {
        switch self {
        case .showFeedAndCount:
            "Show Feed & Count"
        case .showFeedOnly:
            "Show Feed Only"
        case .hideFeed:
            "Hide Feed"
        }
    }

    static func current(isVisible: Bool, showsCount: Bool) -> Self {
        guard isVisible else { return .hideFeed }
        return showsCount ? .showFeedAndCount : .showFeedOnly
    }
}
