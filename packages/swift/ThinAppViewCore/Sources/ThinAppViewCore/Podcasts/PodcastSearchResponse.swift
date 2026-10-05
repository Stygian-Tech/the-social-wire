import Foundation

public struct PodcastSearchResponse: Codable, Sendable {
  public var shows: [PodcastShow]
  public var episodes: [PodcastEpisode]
  public var cursor: String?
  public var hasMore: Bool

  public init(shows: [PodcastShow] = [], episodes: [PodcastEpisode] = [], cursor: String? = nil, hasMore: Bool = false) {
    self.shows = shows
    self.episodes = episodes
    self.cursor = cursor
    self.hasMore = hasMore
  }
}
