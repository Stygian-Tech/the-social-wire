import Foundation

public struct PodcastTranscript: Codable, Sendable, Equatable {
  public var url: String
  public var type: String
  public var language: String?
  public var text: String?
  public var cues: [PodcastTranscriptCue]?
  public init(
    url: String, type: String, language: String? = nil, text: String? = nil,
    cues: [PodcastTranscriptCue]? = nil
  ) {
    self.url = url
    self.type = type
    self.language = language
    self.text = text
    self.cues = cues
  }
}
