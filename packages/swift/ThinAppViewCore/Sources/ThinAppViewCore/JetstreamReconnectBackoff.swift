import Foundation

struct JetstreamReconnectBackoff: Sendable {
  static let initialDelay: TimeInterval = 0.25
  static let maximumDelay: TimeInterval = 30

  static func delay(failureCount: Int, jitter: Double) -> TimeInterval {
    let boundedFailures = min(max(0, failureCount), 16)
    let exponential = initialDelay * pow(2, Double(boundedFailures))
    let boundedJitter = min(max(jitter, 0.8), 1.2)
    return min(maximumDelay, exponential * boundedJitter)
  }

  static func randomizedDelay(failureCount: Int) -> TimeInterval {
    delay(failureCount: failureCount, jitter: Double.random(in: 0.8...1.2))
  }
}
