public enum CircleRankingConfigError: Error, Equatable, Sendable {
  case invalidParticipantBreadthTarget
  case invalidRecencyHalfLife
  case invalidMaximumSignalAge
}
