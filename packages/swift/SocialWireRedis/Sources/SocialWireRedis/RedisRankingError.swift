public enum RedisRankingError: Error, Sendable, Equatable {
  case nonFiniteScore
  case malformedResponse
}
