import Foundation

public struct WirePage: Codable, Equatable, Sendable {
  public let generationID: String
  public let generatedAt: Date
  public let language: String
  public let cursor: String?
  public let source: WirePageSource
  public let degraded: Bool
  public let items: [WireFeedItem]

  public init(
    generationID: String,
    generatedAt: Date,
    language: String,
    cursor: String?,
    source: WirePageSource,
    degraded: Bool,
    items: [WireFeedItem]
  ) {
    self.generationID = generationID
    self.generatedAt = generatedAt
    self.language = language
    self.cursor = cursor
    self.source = source
    self.degraded = degraded
    self.items = Array(items.prefix(50))
  }

  private enum CodingKeys: String, CodingKey {
    case generationID = "generationId"
    case generatedAt
    case language
    case cursor
    case source
    case degraded
    case items
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      generationID: try container.decode(String.self, forKey: .generationID),
      generatedAt: try container.decode(Date.self, forKey: .generatedAt),
      language: try container.decode(String.self, forKey: .language),
      cursor: try container.decodeIfPresent(String.self, forKey: .cursor),
      source: try container.decode(WirePageSource.self, forKey: .source),
      degraded: try container.decode(Bool.self, forKey: .degraded),
      items: try container.decode([WireFeedItem].self, forKey: .items)
    )
  }
}
