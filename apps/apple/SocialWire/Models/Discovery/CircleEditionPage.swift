struct CircleEditionPage: Codable, Equatable, Sendable {
    let editionVersion: String
    let generationId: String
    let generatedAt: String
    let language: String
    let source: WireEditionSource
    let degraded: Bool
    let stories: [CircleStory]
    let topStoryIds: [String]
    let publicationSpotlights: [CirclePublicationSpotlight]
    let storyRails: [CircleStoryRail]
    let trendingStoryIds: [String]
    let moreCursor: String?
}
