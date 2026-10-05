import Foundation

public struct PodcastTranscriptCue: Codable, Sendable, Equatable {
  public var startSeconds: Double
  public var endSeconds: Double?
  public var text: String
  public init(startSeconds: Double, endSeconds: Double? = nil, text: String) {
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
    self.text = text
  }
}
