public struct CircleRankCandidate: Equatable, Sendable {
  public let canonicalKey: String
  public let participantSignals: [CircleParticipantSignal]
  public let quality: Double
  public let presentation: Double
  public let interestMatch: Double

  public init(
    canonicalKey: String,
    participantSignals: [CircleParticipantSignal],
    quality: Double,
    presentation: Double,
    interestMatch: Double
  ) {
    self.canonicalKey = canonicalKey
    self.participantSignals = participantSignals
    self.quality = quality
    self.presentation = presentation
    self.interestMatch = interestMatch
  }
}
