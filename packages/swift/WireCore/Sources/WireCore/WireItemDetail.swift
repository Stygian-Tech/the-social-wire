public struct WireItemDetail: Codable, Equatable, Sendable {
  public let item: WireFeedItem
  public let html: String?
  public let embedURL: String?

  public init(item: WireFeedItem, html: String? = nil, embedURL: String? = nil) {
    self.item = item
    self.html = html
    self.embedURL = embedURL
  }

  private enum CodingKeys: String, CodingKey {
    case item
    case html
    case embedURL = "embedUrl"
  }
}
