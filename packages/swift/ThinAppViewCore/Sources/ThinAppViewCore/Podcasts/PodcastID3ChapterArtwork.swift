import Foundation

public struct PodcastID3ChapterArtwork: Sendable, Equatable {
  public let startSeconds: Double
  public let data: Data
  public let mimeType: String

  public init(startSeconds: Double, data: Data, mimeType: String) {
    self.startSeconds = startSeconds
    self.data = data
    self.mimeType = mimeType
  }
}
