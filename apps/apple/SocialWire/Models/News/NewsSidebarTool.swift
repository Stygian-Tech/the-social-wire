import Foundation

/// Native tools retain web order when their release gate is opened.
enum NewsSidebarTool: String, CaseIterable, Identifiable {
    case articles
    case livePost
    case livestream
    case brandAccounts
    case contentCalendar
    case analytics

    var id: String { rawValue }

    static var availableTools: [Self] {
        SocialWireAPIEnvironment.proFeaturesReleased ? allCases : []
    }

    var title: String {
        switch self {
        case .articles: "Articles"
        case .livePost: "Live Post"
        case .livestream: "Livestream"
        case .brandAccounts: "Brand Accounts"
        case .contentCalendar: "Content Calendar"
        case .analytics: "Analytics"
        }
    }

    var systemImage: String {
        switch self {
        case .articles: "square.and.pencil"
        case .livePost: "dot.radiowaves.left.and.right"
        case .livestream: "video"
        case .brandAccounts: "person.2"
        case .contentCalendar: "calendar"
        case .analytics: "chart.xyaxis.line"
        }
    }
}
