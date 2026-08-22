public struct WireEditionStoryRail: Codable, Equatable, Sendable {
  public static let breakingDevelopingID = "breaking-developing"
  public static let breakingDevelopingTitle = "Breaking & Developing"
  public static let acrossCommunitiesID = "across-communities"
  public static let acrossCommunitiesTitle = "Across Communities"
  public static let resurfacingID = "resurfacing"
  public static let resurfacingTitle = "Resurfacing"

  public let id: String
  public let title: String
  public let reason: WireReasonCode
  public let stories: [WireFeedItem]

  public init(id: String, title: String, reason: WireReasonCode, stories: [WireFeedItem]) {
    self.id = id
    self.title = title
    self.reason = reason
    self.stories = Array(stories.prefix(WireEditionAssembler.maximumStoriesPerRail))
  }

  /// Compatibility initializer for serving adapters that still identify a rail by
  /// one reason. New edition assembly emits only the three stable editorial rails.
  public init(reason: WireReasonCode, stories: [WireFeedItem]) {
    let presentation = Self.presentation(for: reason)
    self.init(id: presentation.id, title: presentation.title, reason: reason, stories: stories)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case reason
    case stories
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let reason = try container.decode(WireReasonCode.self, forKey: .reason)
    let presentation = Self.presentation(for: reason)
    self.init(
      id: try container.decodeIfPresent(String.self, forKey: .id) ?? presentation.id,
      title: try container.decodeIfPresent(String.self, forKey: .title) ?? presentation.title,
      reason: reason,
      stories: try container.decode([WireFeedItem].self, forKey: .stories)
    )
  }

  private static func presentation(for reason: WireReasonCode) -> (id: String, title: String) {
    switch reason {
    case .breakingStory, .widelyDiscussed:
      (breakingDevelopingID, breakingDevelopingTitle)
    case .sharedAcrossCommunities:
      (acrossCommunitiesID, acrossCommunitiesTitle)
    case .resurfacing:
      (resurfacingID, resurfacingTitle)
    case .freshPublication:
      ("fresh-publication", "Fresh Publications")
    }
  }
}
