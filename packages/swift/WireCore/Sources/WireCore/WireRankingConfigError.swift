public enum WireRankingConfigError: Error, Equatable, Sendable {
  case invalidVersion
  case invalidWeight
  case zeroWeightTotal
  case invalidThreshold
  case invalidDiversityCap
}
