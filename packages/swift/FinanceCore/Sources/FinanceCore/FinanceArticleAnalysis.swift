public struct FinanceArticleAnalysis: Codable, Equatable, Sendable {
  public let resolverVersion: String?
  public let eligible: Bool
  public let materiality: String
  public let associations: [FinanceAssociation]
  public let macroTopics: [String]?
  public let sectorIDs: [String]
  public init(eligible: Bool, materiality: String, associations: [FinanceAssociation], sectorIDs: [String], macroTopics: [String] = [], resolverVersion: String? = FinanceResolver.version) {
    self.resolverVersion = resolverVersion
    self.eligible = eligible; self.materiality = materiality
    self.associations = associations; self.sectorIDs = sectorIDs; self.macroTopics = macroTopics
  }
}
