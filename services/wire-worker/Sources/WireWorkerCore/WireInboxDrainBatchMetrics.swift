struct WireInboxDrainBatchMetrics: Equatable, Sendable {
  let attemptedEventCount: Int
  let appliedEventCount: Int

  init(attemptedEventCount: Int, appliedEventCount: Int) {
    self.attemptedEventCount = max(0, attemptedEventCount)
    self.appliedEventCount = max(0, min(appliedEventCount, attemptedEventCount))
  }
}
