import Foundation

/// Process-local timing survives hosted worker replacement after lease loss.
/// Durable graph timestamps remain authoritative across process restarts.
public actor WireGraphMaintenanceScheduler {
  enum Reservation: Equatable, Sendable {
    case wait(milliseconds: Int)
    case run(UUID)
  }

  private let initialDelayMilliseconds: Int
  private var nextAttemptAt: ContinuousClock.Instant?
  private var activeAttempt: UUID?
  private var retryMilliseconds = 60_000

  public init() {
    initialDelayMilliseconds = 60_000
  }

  init(initialDelayMilliseconds: Int) {
    self.initialDelayMilliseconds = max(0, initialDelayMilliseconds)
  }

  func reserve(at now: ContinuousClock.Instant) -> Reservation {
    // Never release a hung attempt merely because another owner asks to run.
    // The hosted runtime's cancellation and teardown watchdog retain ownership.
    guard activeAttempt == nil else { return .wait(milliseconds: 1_000) }
    let deadline = nextAttemptAt ?? now.advanced(by: .milliseconds(initialDelayMilliseconds))
    nextAttemptAt = deadline
    if now < deadline {
      let remaining = now.duration(to: deadline).components
      let milliseconds = Double(remaining.seconds) * 1_000
        + Double(remaining.attoseconds) / 1_000_000_000_000_000
      return .wait(milliseconds: max(1, Int(milliseconds.rounded(.up))))
    }
    let token = UUID()
    activeAttempt = token
    return .run(token)
  }

  func succeeded(_ token: UUID, at now: ContinuousClock.Instant, nextDelayMilliseconds: Int) {
    guard activeAttempt == token else { return }
    activeAttempt = nil
    retryMilliseconds = 60_000
    nextAttemptAt = now.advanced(by: .milliseconds(max(1_000, nextDelayMilliseconds)))
  }

  /// Cancellation of in-flight maintenance is a failed attempt too. Recording
  /// its deadline before returning prevents lease reacquisition bypassing it.
  @discardableResult
  func failed(_ token: UUID, at now: ContinuousClock.Instant) -> Int? {
    guard activeAttempt == token else { return nil }
    activeAttempt = nil
    let delay = retryMilliseconds
    nextAttemptAt = now.advanced(by: .milliseconds(delay))
    retryMilliseconds = min(retryMilliseconds * 2, 300_000)
    return delay
  }
}
