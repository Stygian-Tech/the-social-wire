public struct CircleRankingDiagnostics: Equatable, Sendable {
  public let candidateCount: Int
  public let eligibleCount: Int
  public let rejectedWithoutEligibleParticipants: Int
  public let rejectedForInvalidInput: Int

  public init(
    candidateCount: Int,
    eligibleCount: Int,
    rejectedWithoutEligibleParticipants: Int,
    rejectedForInvalidInput: Int
  ) {
    self.candidateCount = candidateCount
    self.eligibleCount = eligibleCount
    self.rejectedWithoutEligibleParticipants = rejectedWithoutEligibleParticipants
    self.rejectedForInvalidInput = rejectedForInvalidInput
  }
}
