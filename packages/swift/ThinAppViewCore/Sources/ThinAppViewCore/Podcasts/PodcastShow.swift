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
  public var hosts: [PodcastPerson] = []
  enum CodingKeys: String, CodingKey {
    case id, title, description, artworkUrl, feedUrl, sourceKind, sourceUri, guid, episodeCollection, bridgeJobId, bridgeStatus, visibility, hosts
  }
}

extension PodcastShow {
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    title = try values.decode(String.self, forKey: .title)
    description = try values.decodeIfPresent(String.self, forKey: .description)
    artworkUrl = try values.decodeIfPresent(String.self, forKey: .artworkUrl)
    feedUrl = try values.decodeIfPresent(String.self, forKey: .feedUrl)
    sourceKind = try values.decode(String.self, forKey: .sourceKind)
    sourceUri = try values.decodeIfPresent(String.self, forKey: .sourceUri)
    guid = try values.decodeIfPresent(String.self, forKey: .guid)
    episodeCollection = try values.decodeIfPresent(String.self, forKey: .episodeCollection)
    bridgeJobId = try values.decodeIfPresent(String.self, forKey: .bridgeJobId)
    bridgeStatus = try values.decodeIfPresent(String.self, forKey: .bridgeStatus)
    visibility = try values.decodeIfPresent(String.self, forKey: .visibility)
    hosts = try values.decodeIfPresent([PodcastPerson].self, forKey: .hosts) ?? []
  }
}
