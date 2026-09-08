import Foundation

/// Telemetry must release its transaction instead of queuing unlimited work behind ingestion.
/// Each statement receives the smaller of its own timeout and the remaining write budget.
/// Pool acquisition precedes this budget; socket failures remain the client's responsibility.
struct PostgresTelemetryWriteBudget: Sendable {
  enum Exhausted: Error { case transactionBudget }

  private let deadline: ContinuousClock.Instant
  private let statementTimeoutMilliseconds: Int

  init(statementTimeoutMilliseconds: Int, startedAt: ContinuousClock.Instant = .now) {
    deadline = startedAt.advanced(by: .seconds(5))
    self.statementTimeoutMilliseconds = max(1, min(2_000, statementTimeoutMilliseconds))
  }

  func remainingStatementMilliseconds(at now: ContinuousClock.Instant = .now) throws -> Int {
    let remaining = now.duration(to: deadline)
    guard remaining >= .milliseconds(1) else { throw Exhausted.transactionBudget }
    let components = remaining.components
    let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    return min(statementTimeoutMilliseconds, Int(milliseconds))
  }
}
