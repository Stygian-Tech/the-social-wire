public struct RedisRankingCandidate: Sendable, Equatable {
  public let contentId: String
  public let score: Double

  public init(contentId: String, score: Double) throws {
    guard score.isFinite else { throw RedisRankingError.nonFiniteScore }
    self.contentId = contentId
    self.score = score
  }
}
