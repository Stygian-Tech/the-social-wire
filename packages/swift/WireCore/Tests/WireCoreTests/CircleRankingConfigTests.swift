import Testing

@testable import WireCore

@Suite("Your Circle ranking configuration")
struct CircleRankingConfigTests {
  @Test("accepts the deterministic defaults")
  func defaults() throws {
    try CircleRankingConfig().validate()
  }

  @Test("rejects invalid normalization and time bounds")
  func validation() {
    #expect(throws: CircleRankingConfigError.invalidParticipantBreadthTarget) {
      try CircleRankingConfig(participantBreadthTarget: 0).validate()
    }
    #expect(throws: CircleRankingConfigError.invalidRecencyHalfLife) {
      try CircleRankingConfig(recencyHalfLife: 0).validate()
    }
    #expect(throws: CircleRankingConfigError.invalidMaximumSignalAge) {
      try CircleRankingConfig(maximumSignalAge: .infinity).validate()
    }
  }
}
