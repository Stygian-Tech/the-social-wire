public struct WireScoredCandidate: Codable, Equatable, Sendable {
  public var candidate: WireCandidate
  public var score: Double
  public var reasonCodes: [WireReasonCode]

  public init(candidate: WireCandidate, score: Double, reasonCodes: [WireReasonCode]) {
    self.candidate = candidate
    self.score = score
    self.reasonCodes = reasonCodes
  }
}
