import Foundation

enum OPMLImportDestination: String, CaseIterable {
    case publications, podcasts
    var title: String { self == .publications ? "Publications" : "Podcasts" }
}
