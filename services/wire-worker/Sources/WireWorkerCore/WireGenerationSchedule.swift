enum WireGenerationSchedule {
  static func remainingDelay(interval: Duration, elapsed: Duration) -> Duration {
    max(.zero, interval - max(.zero, elapsed))
  }
}
