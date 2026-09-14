import Foundation

/// Keeps complete-cycle timing across materializer lease host replacement.
/// An active attempt stays reserved until its awaited work has finished teardown.
public actor WireRankingScheduler {
  enum Reservation: Equatable, Sendable {
    case wait(milliseconds: Int)
    case run(UUID)
  }

  private var nextAttemptAt: ContinuousClock.Instant?
  private var lastSuccessfulCycleStartedAt: ContinuousClock.Instant?
  private var activeAttempt: (token: UUID, startedAt: ContinuousClock.Instant)?

  public init() {}

  func reserve(at now: ContinuousClock.Instant) -> Reservation {
    guard activeAttempt == nil else { return .wait(milliseconds: 1_000) }
    if let deadline = nextAttemptAt, now < deadline {
      let remaining = now.duration(to: deadline).components
      let milliseconds = Double(remaining.seconds) * 1_000
        + Double(remaining.attoseconds) / 1_000_000_000_000_000
      return .wait(milliseconds: max(1, Int(milliseconds.rounded(.up))))
    }
    let token = UUID()
    activeAttempt = (token, now)
    return .run(token)
  }

  func succeeded(_ token: UUID, at now: ContinuousClock.Instant, intervalSeconds: Int) {
    guard let attempt = activeAttempt, attempt.token == token else { return }
    // Cadence includes processing time. A slow cycle allows one new attempt;
    // that attempt starts a fresh interval rather than replaying missed slots.
    let remaining = WireGenerationSchedule.remainingDelay(
      interval: .seconds(intervalSeconds), elapsed: attempt.startedAt.duration(to: now))
    nextAttemptAt = now.advanced(by: remaining)
    lastSuccessfulCycleStartedAt = attempt.startedAt
    activeAttempt = nil
  }

  /// Retain the original observation age when a new host waits for its next cycle.
  /// This readiness evidence does not fabricate timestamps or refresh telemetry.
  func isGenerationReady(at now: ContinuousClock.Instant, maximumCycleAge: Duration) -> Bool {
    guard let startedAt = lastSuccessfulCycleStartedAt, now >= startedAt else { return false }
    return startedAt.duration(to: now) <= maximumCycleAge
  }

  func failed(_ token: UUID, at now: ContinuousClock.Instant) {
    guard activeAttempt?.token == token else { return }
    nextAttemptAt = now.advanced(by: .seconds(60))
    lastSuccessfulCycleStartedAt = nil
    activeAttempt = nil
  }
}
