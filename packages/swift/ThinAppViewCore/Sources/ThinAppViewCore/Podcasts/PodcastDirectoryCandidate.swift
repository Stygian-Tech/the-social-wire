import Foundation

/// A directory suggestion, not a subscription or canonical catalog identity.
public struct PodcastDirectoryCandidate: Codable, Sendable, Equatable {
  public var provider: String = "podcastindex"
  public var id: String
  public var title: String
  public var description: String?
  public var artworkUrl: String?
  public var feedUrl: String
  public init(id: String, title: String, description: String? = nil, artworkUrl: String? = nil, feedUrl: String) {
    self.id = id
    self.title = title
    self.description = description
    self.artworkUrl = artworkUrl
    self.feedUrl = feedUrl
  }
}
