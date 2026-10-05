import Foundation

/// Stable top-level destinations for the adaptive Apple News-style shell.
enum NewsTab: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case wire
    case circle
    case finance
    case sports
    case library
    case saved
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wire: "The Wire"
        case .circle: "Your Circle"
        case .finance: "Finance"
        case .sports: "Sports"
        case .library: "Library"
        case .saved: "Saved"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .wire: "newspaper"
        case .circle: "person.2.wave.2"
        case .finance: "chart.line.uptrend.xyaxis"
        case .sports: "sportscourt"
        case .library: "books.vertical"
        case .saved: "bookmark"
        case .search: "magnifyingglass"
        }
    }

    static func available(wire: Bool, circle: Bool, finance: Bool = false, sports: Bool = false) -> [NewsTab] {
        allCases.filter { tab in
            switch tab {
            case .wire: wire
            case .circle: circle
            case .finance: finance
            case .sports: sports
            case .library, .saved, .search: true
            }
        }
    }

    static func available(
        preferences: ReaderFeedPreferences,
        wireCatalog: WireFeedCatalog?,
        circleCatalog: CircleFeedCatalog?,
        financeAvailable: Bool = false,
        sportsAvailable: Bool = false
    ) -> [NewsTab] {
        available(
            wire: preferences.showWire && wireCatalog?.isAvailable != false,
            circle: preferences.showCircle && circleCatalog?.enabled != false,
            finance: preferences.showFinance && financeAvailable,
            sports: preferences.showSports && sportsAvailable
        )
    }

    static func defaultTab(in availableTabs: [NewsTab]) -> NewsTab {
        if availableTabs.contains(.wire) { return .wire }
        if availableTabs.contains(.library) { return .library }
        return availableTabs.first ?? .library
    }
}
