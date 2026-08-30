import WireCore

struct CirclePublicationSpotlight: Codable, Equatable, Sendable {
  let id: String
  let publication: WireItemSource
  let storyIDs: [String]

  enum CodingKeys: String, CodingKey {
    case id, publication
    case storyIDs = "storyIds"
  }
}
