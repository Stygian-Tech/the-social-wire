struct WireEditionPage: Codable, Equatable, Sendable {
    let editionVersion: String
    let generationId: String
    let generatedAt: String
    let language: String
    let source: WireEditionSource
    let degraded: Bool
    let stories: [WireFeedItem]
    let topStoryIds: [String]
    let publicationSpotlights: [WirePublicationSpotlight]
    let storyRails: [WireStoryRail]
    let people: [WireTalkedAboutPerson]
    let trendingStoryIds: [String]
    let moreCursor: String?
}
