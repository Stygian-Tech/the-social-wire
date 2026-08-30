import Foundation

public struct WireCorpusCandidateResponse: Codable, Equatable, Sendable {
  public let generationID: String
  public let generatedAt: Date
  public let language: String
  public let stories: [WireCorpusCandidateStory]
  public let exhausted: Bool

  public init(
    generationID: String,
    generatedAt: Date,
    language: String,
    stories: [WireCorpusCandidateStory],
    exhausted: Bool
  ) {
    self.generationID = generationID
    self.generatedAt = generatedAt
    self.language = language
    self.stories = stories
    self.exhausted = exhausted
  }
}
