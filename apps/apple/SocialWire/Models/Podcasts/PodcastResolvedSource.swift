import Foundation

struct PodcastResolvedSource: Decodable, Sendable {
    let show: PodcastShow
    let episodes: [PodcastEpisode]
}
