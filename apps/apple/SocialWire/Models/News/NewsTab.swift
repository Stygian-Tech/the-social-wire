import Foundation

/// Stable top-level destinations for the adaptive Apple News-style shell.
enum NewsTab: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case wire
    case circle
    case library
    case saved
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wire: "The Wire"
        case .circle: "Your Circle"
        case .library: "Library"
        case .saved: "Saved"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .wire: "newspaper"
        case .circle: "person.2.wave.2"
        case .library: "books.vertical"
        case .saved: "bookmark"
        case .search: "magnifyingglass"
        }
    }

    static func available(wire: Bool, circle: Bool) -> [NewsTab] {
        allCases.filter { tab in
            switch tab {
            case .wire: wire
            case .circle: circle
            case .library, .saved, .search: true
            }
        }
    }

    static func defaultTab(in availableTabs: [NewsTab]) -> NewsTab {
        if availableTabs.contains(.wire) { return .wire }
        if availableTabs.contains(.library) { return .library }
        return availableTabs.first ?? .library
    }
}
