struct WireRecommendationRecoveryCounts: Sendable {
  var attempted = 0
  var resolved = 0
  var pending = 0
  var conflicted = 0
  var superseded = 0
}
