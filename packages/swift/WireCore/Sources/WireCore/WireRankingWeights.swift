public struct WireRankingWeights: Codable, Equatable, Sendable {
  public var distinctSharers24h: Double
  public var shareVelocity1h: Double
  public var likeBreadthVelocity: Double
  public var repostBreadthVelocity: Double
  public var communitySpread: Double
  public var freshness: Double
  public var resurfacingAcceleration: Double
  public var sourceConfidence: Double
  public var standardSiteAuthority: Double
  public var openGraphMetadata: Double

  public init(
    distinctSharers24h: Double = 0.22,
    shareVelocity1h: Double = 0.14,
    likeBreadthVelocity: Double = 0.04,
    repostBreadthVelocity: Double = 0.04,
    communitySpread: Double = 0.18,
    freshness: Double = 0.10,
    resurfacingAcceleration: Double = 0.06,
    sourceConfidence: Double = 0.08,
    standardSiteAuthority: Double = 0.09,
    openGraphMetadata: Double = 0.05
  ) {
    self.distinctSharers24h = distinctSharers24h
    self.shareVelocity1h = shareVelocity1h
    self.likeBreadthVelocity = likeBreadthVelocity
    self.repostBreadthVelocity = repostBreadthVelocity
    self.communitySpread = communitySpread
    self.freshness = freshness
    self.resurfacingAcceleration = resurfacingAcceleration
    self.sourceConfidence = sourceConfidence
    self.standardSiteAuthority = standardSiteAuthority
    self.openGraphMetadata = openGraphMetadata
  }

  var all: [Double] {
    [
      distinctSharers24h, shareVelocity1h, likeBreadthVelocity, repostBreadthVelocity,
      communitySpread, freshness, resurfacingAcceleration, sourceConfidence,
      standardSiteAuthority, openGraphMetadata,
    ]
  }
}
