struct WireRecommendationBacklog: Sendable {
  let pendingCount: Int
  let conflictCount: Int
  let oldestPendingAgeSeconds: Double
  let oldestConflictAgeSeconds: Double
  let countLimit: Int
}
