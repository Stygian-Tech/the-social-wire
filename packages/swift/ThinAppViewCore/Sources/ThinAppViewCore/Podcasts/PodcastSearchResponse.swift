import Foundation

public struct PodcastSearchResponse: Codable, Sendable {
  public var shows: [PodcastShow]
  public var episodes: [PodcastEpisode]
  public var cursor: String?
  public var candidates: [PodcastDirectoryCandidate] = []
  public var directoryLimit: Int? = nil
  public var hasMore: Bool

  enum CodingKeys: String, CodingKey { case shows, episodes, candidates, directoryLimit, cursor, hasMore }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    shows = try values.decode([PodcastShow].self, forKey: .shows)
    episodes = try values.decode([PodcastEpisode].self, forKey: .episodes)
    candidates = try values.decodeIfPresent([PodcastDirectoryCandidate].self, forKey: .candidates) ?? []
    directoryLimit = try values.decodeIfPresent(Int.self, forKey: .directoryLimit)
    cursor = try values.decodeIfPresent(String.self, forKey: .cursor)
    hasMore = try values.decode(Bool.self, forKey: .hasMore)
  }

  public init(shows: [PodcastShow] = [], episodes: [PodcastEpisode] = [], cursor: String? = nil, hasMore: Bool = false) {
    self.shows = shows
    self.episodes = episodes
    self.cursor = cursor
    self.hasMore = hasMore
  }
}
