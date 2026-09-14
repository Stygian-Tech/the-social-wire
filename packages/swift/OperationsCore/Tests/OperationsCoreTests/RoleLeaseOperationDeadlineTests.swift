import Foundation
import Testing
@testable import OperationsCore

@Suite("Absolute lease control deadline")
struct RoleLeaseOperationDeadlineTests {
  @Test("the three second deadline rejects equality and late responses without a timer task")
  func strictBoundary() throws {
    let clock = LeaseOperationTestClock()
    let deadline = RoleLeaseOperationDeadline(startedAt: clock.now, now: { clock.now })
    var submissions = 0
    clock.advance(.seconds(3) - .nanoseconds(1))
    try deadline.submit { submissions += 1 }
    #expect(submissions == 1)
    clock.advance(.nanoseconds(1))
    #expect(throws: RoleLeaseFailure.operationTimedOut) {
      try deadline.submit { submissions += 1 }
    }
    #expect(submissions == 1)
    clock.advance(.seconds(60))
    #expect(throws: RoleLeaseFailure.operationTimedOut) { try deadline.check() }
  }
}

final class LeaseOperationTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = ContinuousClock.now
  var now: ContinuousClock.Instant { lock.withLock { instant } }
  func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
