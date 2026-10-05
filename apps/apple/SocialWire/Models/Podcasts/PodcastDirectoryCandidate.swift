import Foundation

struct PodcastDirectoryCandidate: Codable, Identifiable, Sendable {
    let provider: String
    let id: String
    let title: String
    let description: String?
    let artworkUrl: String?
    let feedUrl: String
    let author: String?
}
