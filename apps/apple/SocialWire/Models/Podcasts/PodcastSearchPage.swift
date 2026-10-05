import Foundation

struct PodcastSearchPage: Codable, Sendable {
    let shows: [PodcastShow]
    let episodes: [PodcastEpisode]
    let cursor: String?
    let hasMore: Bool
    let candidates: [PodcastDirectoryCandidate]?

    init(shows: [PodcastShow], episodes: [PodcastEpisode], cursor: String?, hasMore: Bool, candidates: [PodcastDirectoryCandidate]? = nil) {
        self.shows = shows
        self.episodes = episodes
        self.cursor = cursor
        self.hasMore = hasMore
        self.candidates = candidates
    }
}
