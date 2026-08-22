import Foundation

public struct WireEdition: Codable, Equatable, Sendable {
  public let algorithmVersion: String
  public let generationID: String
  public let generatedAt: Date
  public let language: String
  public let cursor: String?
  public let source: WirePageSource
  public let degraded: Bool
  public let leadStories: [WireFeedItem]
  public let publicationPanels: [WireEditionPublicationPanel]
  public let storyRails: [WireEditionStoryRail]
  public let generalStories: [WireFeedItem]
  public let trendingStories: [WireFeedItem]
  public let talkedAboutAccounts: [WireTalkedAboutAccount]

  public init(
    algorithmVersion: String = WireEditionAssembler.version,
    generationID: String,
    generatedAt: Date,
    language: String,
    cursor: String?,
    source: WirePageSource,
    degraded: Bool,
    leadStories: [WireFeedItem],
    publicationPanels: [WireEditionPublicationPanel],
    storyRails: [WireEditionStoryRail],
    generalStories: [WireFeedItem],
    trendingStories: [WireFeedItem],
    talkedAboutAccounts: [WireTalkedAboutAccount]
  ) {
    self.algorithmVersion = algorithmVersion
    self.generationID = generationID
    self.generatedAt = generatedAt
    self.language = language
    self.cursor = cursor
    self.source = source
    self.degraded = degraded
    self.leadStories = Array(leadStories.prefix(WireEditionAssembler.maximumLeadStories))
    self.publicationPanels = Array(
      publicationPanels.prefix(WireEditionAssembler.maximumPublicationPanels)
    )
    self.storyRails = Array(storyRails.prefix(WireEditionAssembler.maximumStoryRails))
    self.generalStories = generalStories
    self.trendingStories = Array(
      trendingStories.prefix(WireEditionAssembler.maximumTrendingStories)
    )
    self.talkedAboutAccounts = Array(
      talkedAboutAccounts.prefix(WireEditionAssembler.maximumTalkedAboutAccounts)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case algorithmVersion
    case generationID = "generationId"
    case generatedAt
    case language
    case cursor
    case source
    case degraded
    case leadStories
    case publicationPanels
    case storyRails
    case generalStories
    case trendingStories
    case talkedAboutAccounts
  }
}
