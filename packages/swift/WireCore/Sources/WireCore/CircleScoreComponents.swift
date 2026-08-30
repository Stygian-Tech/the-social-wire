public struct CircleScoreComponents: Equatable, Sendable {
  public let participantBreadth: Double
  public let relationshipStrength: Double
  public let recencyVelocity: Double
  public let qualityPresentation: Double
  public let interestMatch: Double

  public init(
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
