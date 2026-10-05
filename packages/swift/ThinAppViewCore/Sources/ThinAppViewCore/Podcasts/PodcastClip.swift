import Foundation

public struct PodcastClip: Codable, Sendable, Equatable {
  public var id: String
  public var episodeId: String
  public var sourceUri: String?
  public var jobId: String?
  public var startSeconds: Double
  public var endSeconds: Double
  public var title: String
  public var status: String
  public var audioUrl: String?
  public var videoUrl: String?
  public var publicAudioUrl: String?
  public var publicVideoUrl: String?
  public var audioKey: String?
  public var videoKey: String?
  public var durationSeconds: Double?
  public var publishedUri: String?
  public var createdAt: String
  public init(
    id: String, episodeId: String, startSeconds: Double, endSeconds: Double, title: String,
    status: String = "queued", createdAt: String
  ) {
    self.id = id
    self.episodeId = episodeId
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
    self.title = title
    self.status = status
    self.createdAt = createdAt
  }
}
