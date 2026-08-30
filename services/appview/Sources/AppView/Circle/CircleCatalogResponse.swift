import Foundation

struct CircleCatalogResponse: Codable, Equatable, Sendable {
  let enabled: Bool
  let available: Bool
  let title: String
  let subtitle: String
  let supportedLanguages: [String]
  let latestGenerationID: String?
  let generatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case enabled, available, title, subtitle, supportedLanguages, generatedAt
    case latestGenerationID = "latestGenerationId"
  }
}
