import Foundation

public struct WireCorpusCatalog: Codable, Equatable, Sendable {
  public let available: Bool
  public let supportedLanguages: [String]
  public let latestGenerationID: String?
  public let generatedAt: Date?

  public init(
    available: Bool,
    supportedLanguages: [String],
    latestGenerationID: String?,
    generatedAt: Date?
  ) {
    self.available = available
    self.supportedLanguages = Array(supportedLanguages.prefix(12))
    self.latestGenerationID = latestGenerationID
    self.generatedAt = generatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case available
    case supportedLanguages
    case latestGenerationID = "latestGenerationId"
    case generatedAt
  }
}
