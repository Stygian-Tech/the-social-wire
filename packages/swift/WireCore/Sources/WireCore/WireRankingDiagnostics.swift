public struct WireRankingDiagnostics: Codable, Equatable, Sendable {
  public var candidateCount: Int
  public var eligibleCount: Int
  public var rejectedForAge: Int
  public var rejectedForQuality: Int
  public var rejectedForSignalFloor: Int
  public var qualityBackfillCount: Int
  public var generalBackfillCount: Int
  public var diversityDeferrals: Int

  public init(
    candidateCount: Int,
    eligibleCount: Int,
    rejectedForAge: Int,
    rejectedForQuality: Int,
    rejectedForSignalFloor: Int,
    qualityBackfillCount: Int = 0,
    generalBackfillCount: Int = 0,
    diversityDeferrals: Int
  ) {
    self.candidateCount = candidateCount
    self.eligibleCount = eligibleCount
    self.rejectedForAge = rejectedForAge
    self.rejectedForQuality = rejectedForQuality
    self.rejectedForSignalFloor = rejectedForSignalFloor
    self.qualityBackfillCount = qualityBackfillCount
    self.generalBackfillCount = generalBackfillCount
    self.diversityDeferrals = diversityDeferrals
  }
}
