struct CircleStoryRail: Codable, Equatable, Sendable {
  let id: String
  let title: String
  let storyIDs: [String]

  enum CodingKeys: String, CodingKey {
    case id, title
    case storyIDs = "storyIds"
  }
}
