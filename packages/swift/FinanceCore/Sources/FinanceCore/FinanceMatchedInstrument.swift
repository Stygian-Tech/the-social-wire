import Foundation

public struct FinanceMatchedInstrument: Codable, Equatable, Sendable {
  public let instrument: FinanceInstrument
  public let confidence: Double
  public let prominence: Int
  public let resolverVersion: String
  public let evidence: [String]
  public init(instrument: FinanceInstrument, confidence: Double, prominence: Int, evidence: [String] = [], resolverVersion: String = FinanceResolver.version) {
    self.instrument = instrument; self.confidence = confidence; self.prominence = prominence; self.evidence = evidence; self.resolverVersion = resolverVersion
  }

  private enum CodingKeys: String, CodingKey { case instrument, confidenceBps, prominence, evidence, resolverVersion }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let bps = try c.decode(Int.self, forKey: .confidenceBps)
    guard (0...10000).contains(bps) else {
      throw DecodingError.dataCorruptedError(forKey: .confidenceBps, in: c, debugDescription: "Confidence must be within 0...10000")
    }
    self.init(instrument: try c.decode(FinanceInstrument.self, forKey: .instrument),
      confidence: Double(bps) / 10000, prominence: try c.decode(Int.self, forKey: .prominence),
      evidence: try c.decodeIfPresent([String].self, forKey: .evidence) ?? [], resolverVersion: try c.decodeIfPresent(String.self, forKey: .resolverVersion) ?? "finance-resolver-v1")
  }
  public func encode(to encoder: Encoder) throws {
    guard confidence.isFinite, (0...1).contains(confidence) else {
      throw EncodingError.invalidValue(confidence, .init(codingPath: encoder.codingPath, debugDescription: "Invalid confidence"))
    }
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(instrument, forKey: .instrument)
    try c.encode(Int((confidence * 10000).rounded()), forKey: .confidenceBps)
    try c.encode(prominence, forKey: .prominence)
    try c.encode(evidence, forKey: .evidence)
    try c.encode(resolverVersion, forKey: .resolverVersion)
  }
}
