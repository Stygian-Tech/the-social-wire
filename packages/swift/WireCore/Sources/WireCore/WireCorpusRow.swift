public struct WireCorpusRow: Codable, Equatable, Sendable {
  public let ordinal: Int
  public let item: WireFeedItem
  public let sourceActorKey: String?

  public init(ordinal: Int, item: WireFeedItem, sourceActorKey: String?) {
    self.ordinal = ordinal
    self.item = item
    self.sourceActorKey = sourceActorKey
  }
}
