import Foundation

struct PodcastChapter: Codable, Hashable, Sendable {
    let startSeconds: Double
    let title: String
    let artworkUrl: String?
    let url: String?
}
