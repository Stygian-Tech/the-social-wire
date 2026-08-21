import Testing
@testable import WireCore

@Suite("The Wire ranking configuration")
struct WireRankingConfigTests {
  @Test("default configuration is valid")
  func validDefault() throws {
    try WireRankingConfig().validate()
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
        resurfacingAcceleration: 0, sourceConfidence: 0
      )).validate()
    }

    #expect(throws: WireRankingConfigError.invalidDiversityCap) {
      try WireRankingConfig(diversity: .init(maxPerDomain: 0)).validate()
    }
  }
}
