public struct WireCorpusCandidateStory: Codable, Equatable, Sendable {
  public let item: WireFeedItem
  public let topicKeys: [String]
  public let facts: [WireCorpusSignalFact]

  public init(item: WireFeedItem, topicKeys: [String] = [], facts: [WireCorpusSignalFact]) {
    self.item = item
    self.topicKeys = topicKeys
    self.facts = facts
  }
}
