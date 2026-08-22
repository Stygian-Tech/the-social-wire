public struct WireEditionPublicationPanel: Codable, Equatable, Sendable {
  public let publication: WireEditionPublication
  public let stories: [WireFeedItem]

  public init(publication: WireEditionPublication, stories: [WireFeedItem]) {
    self.publication = publication
    self.stories = Array(stories.prefix(WireEditionAssembler.maximumStoriesPerPublicationPanel))
  }
}
