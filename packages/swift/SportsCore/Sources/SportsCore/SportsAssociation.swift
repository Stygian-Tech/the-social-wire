public struct SportsAssociation: Codable, Equatable, Sendable {
  public let entityID: String
  public let confidence: Double
  public let evidence: [String]
  public let prominence: Int
  public let resolverVersion: String
  public init(entityID: String, confidence: Double, evidence: [String], prominence: Int,
    resolverVersion: String = SportsResolver.version) {
    self.entityID = entityID; self.confidence = confidence; self.evidence = evidence
    self.prominence = prominence; self.resolverVersion = resolverVersion
  }
}
