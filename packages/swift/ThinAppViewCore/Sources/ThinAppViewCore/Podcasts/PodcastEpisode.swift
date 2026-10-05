import Foundation

public struct PodcastEpisode: Codable, Sendable, Equatable {
  public var id: String
  public var showId: String
  public var title: String
  public var description: String?
  public var publishedAt: String
  public var audioUrl: String
  public var audioMimeType: String?
  public var durationSeconds: Double?
  public var artworkUrl: String?
  public var guid: String?
  public var sourceUri: String?
  public var transcripts: [PodcastTranscript]
  public var visibility: String? = nil
  public var chapters: [PodcastChapter] = []
  public var chapterSourceUrl: String? = nil
  public var showArtworkUrl: String? = nil
  enum CodingKeys: String, CodingKey {
    case id, showId, title, description, publishedAt, audioUrl, audioMimeType, durationSeconds, artworkUrl, guid, sourceUri, transcripts, visibility, chapters, chapterSourceUrl, showArtworkUrl
  }
}

extension PodcastEpisode {
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    showId = try values.decode(String.self, forKey: .showId)
    title = try values.decode(String.self, forKey: .title)
    description = try values.decodeIfPresent(String.self, forKey: .description)
    publishedAt = try values.decode(String.self, forKey: .publishedAt)
    audioUrl = try values.decode(String.self, forKey: .audioUrl)
    audioMimeType = try values.decodeIfPresent(String.self, forKey: .audioMimeType)
    durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
    artworkUrl = try values.decodeIfPresent(String.self, forKey: .artworkUrl)
    guid = try values.decodeIfPresent(String.self, forKey: .guid)
    sourceUri = try values.decodeIfPresent(String.self, forKey: .sourceUri)
    transcripts = try values.decode([PodcastTranscript].self, forKey: .transcripts)
    visibility = try values.decodeIfPresent(String.self, forKey: .visibility)
    chapters = try values.decodeIfPresent([PodcastChapter].self, forKey: .chapters) ?? []
    chapterSourceUrl = try values.decodeIfPresent(String.self, forKey: .chapterSourceUrl)
    showArtworkUrl = try values.decodeIfPresent(String.self, forKey: .showArtworkUrl)
  }
}
