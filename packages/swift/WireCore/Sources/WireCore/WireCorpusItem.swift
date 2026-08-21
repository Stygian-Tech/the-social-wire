public struct WireCorpusItem: Codable, Equatable, Sendable {
  public let item: WireFeedItem
  public let sourceActorKey: String?

  public init(item: WireFeedItem, sourceActorKey: String?) {
    self.item = item
    self.sourceActorKey = sourceActorKey
  }
}
