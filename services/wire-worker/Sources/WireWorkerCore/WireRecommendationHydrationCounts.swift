struct WireRecommendationHydrationCounts: Equatable, Sendable {
  var attempted = 0
  var verified = 0
  var staged = 0
  var unavailable = 0
  var superseded = 0

  mutating func add(_ other: Self) {
    attempted += other.attempted
    verified += other.verified
    staged += other.staged
    unavailable += other.unavailable
    superseded += other.superseded
  }
}
