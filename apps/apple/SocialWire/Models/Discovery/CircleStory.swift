struct CircleStory: Codable, Equatable, Sendable {
    let storyId: String
    let canonicalUrl: String
    let representativeUri: String?
    let title: String
    let summary: String?
    let publishedAt: String?
    let thumbnailUrl: String?
    let source: WireFeedSource
    let reasons: [String]
    let discussionCount: Int
    let sharers: [CircleSharer]

}
