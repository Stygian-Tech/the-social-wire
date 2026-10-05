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
}
