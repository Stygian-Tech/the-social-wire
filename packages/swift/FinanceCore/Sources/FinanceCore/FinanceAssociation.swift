public struct FinanceAssociation: Codable, Equatable, Sendable {
  public let instrumentID: String
  public let confidence: Double
  public let evidence: [String]
  public let prominence: Int
  public let resolverVersion: String
  public init(instrumentID: String, confidence: Double, evidence: [String], prominence: Int,
    resolverVersion: String = FinanceResolver.version) {
    self.instrumentID = instrumentID; self.confidence = confidence; self.evidence = evidence
    self.prominence = prominence; self.resolverVersion = resolverVersion
  }
}
