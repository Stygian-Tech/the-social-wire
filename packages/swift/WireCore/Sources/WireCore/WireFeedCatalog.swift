import Foundation

public struct WireFeedCatalog: Codable, Equatable, Sendable {
  public let enabled: Bool
  public let available: Bool
  public let title: String
  public let subtitle: String
  public let supportedLanguages: [String]
  public let latestGenerationID: String?
  public let generatedAt: Date?

  public init(
    enabled: Bool,
    available: Bool,
    title: String = "The Wire",
    subtitle: String = "Important stories across the social web",
    supportedLanguages: [String],
    latestGenerationID: String? = nil,
    generatedAt: Date? = nil
  ) {
    self.enabled = enabled
    self.available = available
    self.title = title
    self.subtitle = subtitle
    self.supportedLanguages = Array(supportedLanguages.prefix(12))
    self.latestGenerationID = latestGenerationID
    self.generatedAt = generatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case enabled
    case available
    case title
    case subtitle
    case supportedLanguages
    case latestGenerationID = "latestGenerationId"
    case generatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try container.decode(Bool.self, forKey: .enabled),
      available: try container.decode(Bool.self, forKey: .available),
      title: try container.decode(String.self, forKey: .title),
      subtitle: try container.decode(String.self, forKey: .subtitle),
      supportedLanguages: try container.decode([String].self, forKey: .supportedLanguages),
      latestGenerationID: try container.decodeIfPresent(String.self, forKey: .latestGenerationID),
      generatedAt: try container.decodeIfPresent(Date.self, forKey: .generatedAt)
    )
  }
}
