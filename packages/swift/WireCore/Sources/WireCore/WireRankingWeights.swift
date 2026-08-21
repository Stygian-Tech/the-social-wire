public struct WireRankingWeights: Codable, Equatable, Sendable {
  public var distinctSharers24h: Double
  public var shareVelocity1h: Double
  public var likeBreadthVelocity: Double
  public var repostBreadthVelocity: Double
  public var communitySpread: Double
  public var freshness: Double
  public var resurfacingAcceleration: Double
  public var sourceConfidence: Double

  public init(
    distinctSharers24h: Double = 0.24,
    shareVelocity1h: Double = 0.20,
    likeBreadthVelocity: Double = 0.08,
    repostBreadthVelocity: Double = 0.08,
    communitySpread: Double = 0.15,
    freshness: Double = 0.12,
    resurfacingAcceleration: Double = 0.08,
    sourceConfidence: Double = 0.05
  ) {
    self.distinctSharers24h = distinctSharers24h
    self.shareVelocity1h = shareVelocity1h
    self.likeBreadthVelocity = likeBreadthVelocity
    self.repostBreadthVelocity = repostBreadthVelocity
    self.communitySpread = communitySpread
    self.freshness = freshness
    self.resurfacingAcceleration = resurfacingAcceleration
    self.sourceConfidence = sourceConfidence
  }

  var all: [Double] {
    [
      distinctSharers24h, shareVelocity1h, likeBreadthVelocity, repostBreadthVelocity,
      communitySpread, freshness, resurfacingAcceleration, sourceConfidence,
    ]
  }
}
