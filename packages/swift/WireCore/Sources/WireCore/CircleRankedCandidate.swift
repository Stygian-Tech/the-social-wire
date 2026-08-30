/// Internal ranking output. It is intentionally not Codable and must not be used as a public DTO.
public struct CircleRankedCandidate: Equatable, Sendable {
  public let candidate: CircleRankCandidate
  public let score: Double
  public let components: CircleScoreComponents

  public init(
    candidate: CircleRankCandidate,
    score: Double,
    components: CircleScoreComponents
  ) {
    self.candidate = candidate
    self.score = score
    self.components = components
  }
}
