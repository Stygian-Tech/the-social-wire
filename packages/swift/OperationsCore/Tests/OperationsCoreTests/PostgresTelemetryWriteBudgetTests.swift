import Foundation
import Testing

@testable import OperationsCore

@Suite("Postgres telemetry write budget")
struct PostgresTelemetryWriteBudgetTests {
  @Test("statement budget shrinks across a transaction and expires without restarting")
  func cumulativeDeadline() throws {
    let start = ContinuousClock.now
    let budget = PostgresTelemetryWriteBudget(statementTimeoutMilliseconds: 2_000, startedAt: start)
    #expect(try budget.remainingStatementMilliseconds(at: start) == 2_000)
    #expect(try budget.remainingStatementMilliseconds(at: start.advanced(by: .milliseconds(4_250))) == 750)
    #expect(throws: PostgresTelemetryWriteBudget.Exhausted.self) {
      try budget.remainingStatementMilliseconds(at: start.advanced(by: .seconds(5)))
    }
  }

  @Test("caller timeouts stay positive and cannot exceed the safe per-statement limit")
  func clampedStatementTimeout() throws {
    let start = ContinuousClock.now
    for (configured, expected) in [(-1, 1), (0, 1), (100, 100), (20_000, 2_000)] {
      let budget = PostgresTelemetryWriteBudget(statementTimeoutMilliseconds: configured, startedAt: start)
      #expect(try budget.remainingStatementMilliseconds(at: start) == expected)
    }
  }
}
