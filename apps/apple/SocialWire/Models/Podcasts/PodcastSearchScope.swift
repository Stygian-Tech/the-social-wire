import Foundation

enum PodcastSearchScope: String, CaseIterable, Sendable {
    case library
    case discover = "directory"
    var title: String { self == .library ? "Library" : "Search" }
}
