public struct CircleRankingWeights: Equatable, Sendable {
  public let participantBreadth: Double
  public let relationshipStrength: Double
  public let recencyVelocity: Double
  public let qualityPresentation: Double
  public let interestMatch: Double

  public static let standard = CircleRankingWeights(
    participantBreadth: 0.35,
    relationshipStrength: 0.25,
    recencyVelocity: 0.20,
    qualityPresentation: 0.10,
    interestMatch: 0.10
  )

  private init(
    participantBreadth: Double,
    relationshipStrength: Double,
    recencyVelocity: Double,
    qualityPresentation: Double,
    interestMatch: Double
  ) {
    self.participantBreadth = participantBreadth
    self.relationshipStrength = relationshipStrength
    self.recencyVelocity = recencyVelocity
    self.qualityPresentation = qualityPresentation
    self.interestMatch = interestMatch
  }
}
