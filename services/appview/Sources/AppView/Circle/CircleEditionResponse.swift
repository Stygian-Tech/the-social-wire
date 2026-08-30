import Foundation

struct CircleEditionResponse: Codable, Equatable, Sendable {
  let editionVersion: String
  let generationID: String
  let generatedAt: Date
  let language: String
  let source: String
  let degraded: Bool
  let stories: [CircleStory]
  let topStoryIDs: [String]
  let publicationSpotlights: [CirclePublicationSpotlight]
  let storyRails: [CircleStoryRail]
  let trendingStoryIDs: [String]
  let moreCursor: String?

  enum CodingKeys: String, CodingKey {
    case editionVersion, generatedAt, language, source, degraded, stories
    case publicationSpotlights, storyRails, moreCursor
    case generationID = "generationId"
    case topStoryIDs = "topStoryIds"
    case trendingStoryIDs = "trendingStoryIds"
  }
}
