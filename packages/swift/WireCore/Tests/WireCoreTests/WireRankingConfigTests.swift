import Testing
@testable import WireCore

@Suite("The Wire ranking configuration")
struct WireRankingConfigTests {
  @Test("default configuration is valid")
  func validDefault() throws {
    let config = WireRankingConfig()
    try config.validate()
    #expect(config.version == "wire-v5")
    #expect(config.freshnessHalfLife == 36_000)
    #expect(config.weights.shareVelocity1h == 0.10)
    #expect(config.weights.likeBreadthVelocity == 0.02)
    #expect(config.weights.repostBreadthVelocity == 0.02)
    #expect(config.weights.communitySpread == 0.14)
    #expect(config.weights.freshness == 0.18)
    #expect(config.weights.standardSiteAuthority == 0.11)
    #expect(config.weights.recommendationBreadth == 0.10)
    #expect(abs(config.weights.all.reduce(0, +) - 1.14) < 0.000_001)
  }

  @Test("rejects invalid weights and caps")
  func rejectsInvalidConfiguration() {
    var weights = WireRankingWeights()
    weights.shareVelocity1h = -0.01
    #expect(throws: WireRankingConfigError.invalidWeight) {
      try WireRankingConfig(weights: weights).validate()
    }

    #expect(throws: WireRankingConfigError.zeroWeightTotal) {
      try WireRankingConfig(weights: .init(
        distinctSharers24h: 0, shareVelocity1h: 0, likeBreadthVelocity: 0,
        repostBreadthVelocity: 0, communitySpread: 0, freshness: 0,
        resurfacingAcceleration: 0, sourceConfidence: 0,
        standardSiteAuthority: 0, openGraphMetadata: 0,
        recommendationBreadth: 0, positiveFeedbackBreadth: 0
      )).validate()
    }

    #expect(throws: WireRankingConfigError.invalidDiversityCap) {
      try WireRankingConfig(diversity: .init(maxPerDomain: 0)).validate()
    }
  }

  @Test("rejects invalid domain penalties")
  func rejectsInvalidDomainPenalties() {
    #expect(throws: WireRankingConfigError.invalidThreshold) {
      try WireRankingConfig(
        domainPenalties: .init(penalties: ["youtube.com": 0.21])
      ).validate()
    }
    #expect(throws: WireRankingConfigError.invalidThreshold) {
      try WireRankingConfig(
        domainPenalties: .init(penalties: ["YouTube.com": 0.06])
      ).validate()
    }
  }
}
