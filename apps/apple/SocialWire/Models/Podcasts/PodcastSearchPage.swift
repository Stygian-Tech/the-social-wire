import Foundation

struct PodcastSearchPage: Codable, Sendable {
    let shows: [PodcastShow]
    let episodes: [PodcastEpisode]
    let cursor: String?
    let hasMore: Bool
}
