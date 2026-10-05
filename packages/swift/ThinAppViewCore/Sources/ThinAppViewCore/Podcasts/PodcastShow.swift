import Foundation

public struct PodcastShow: Codable, Sendable, Equatable {
  public var id: String
  public var title: String
  public var description: String?
  public var artworkUrl: String?
  public var feedUrl: String?
  public var sourceKind: String
  public var sourceUri: String?
  public var guid: String?
  public var episodeCollection: String?
  public var bridgeJobId: String?
  public var bridgeStatus: String?
  public var visibility: String? = nil
}
