import Foundation

struct PodcastShow: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String?
    let artworkUrl: String?
    let feedUrl: String?
    let sourceKind: String
    let sourceUri: String?
    let guid: String?
    let episodeCollection: String?
    let visibility: String?
    var isPrivate: Bool { sourceKind == "private-rss" || visibility == "private" }
}
