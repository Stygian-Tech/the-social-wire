struct WireStoryRail: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let storyIds: [String]
}
