public enum WireReasonCode: String, Codable, CaseIterable, Sendable {
  case breakingStory = "breaking_story"
  case freshPublication = "fresh_publication"
  case resurfacing = "resurfacing"
  case sharedAcrossCommunities = "shared_across_communities"
  case widelyDiscussed = "widely_discussed"
}
