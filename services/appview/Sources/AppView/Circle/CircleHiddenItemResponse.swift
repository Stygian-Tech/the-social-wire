struct CircleHiddenItemResponse: Codable, Equatable, Sendable {
  let storyID: String
  let hidden: Bool

  enum CodingKeys: String, CodingKey {
    case hidden
    case storyID = "storyId"
  }
}
