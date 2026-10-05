public struct FinanceSector: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let keywords: [String]
  public init(id: String, name: String, keywords: [String]) {
    self.id = id; self.name = name; self.keywords = keywords
  }
  public static let taxonomyVersion = "finance-sectors-v1"
  public static let all: [FinanceSector] = [
    .init(id: "technology", name: "Technology", keywords: ["semiconductor", "software", "technology"]),
    .init(id: "healthcare", name: "Healthcare", keywords: ["pharmaceutical", "healthcare", "biotech"]),
    .init(id: "financials", name: "Financials", keywords: ["bank", "insurance", "financial"]),
    .init(id: "energy", name: "Energy", keywords: ["oil", "energy", "natural gas"]),
    .init(id: "materials", name: "Materials", keywords: ["mining", "metals", "chemicals"]),
    .init(id: "industrials", name: "Industrials", keywords: ["manufacturing", "aerospace", "industrial"]),
    .init(id: "consumer", name: "Consumer", keywords: ["retail", "consumer", "automotive"]),
    .init(id: "communications", name: "Communications", keywords: ["telecom", "media"]),
    .init(id: "utilities", name: "Utilities", keywords: ["utilities", "electric utility"]),
    .init(id: "real-estate", name: "Real Estate", keywords: ["real estate", "housing"])
  ]
}
