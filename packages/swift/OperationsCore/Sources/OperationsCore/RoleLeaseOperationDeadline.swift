import Foundation

/// A timer wakes cancellation, but is not authority to accept a late result.
/// Every control attempt has this independent, absolute monotonic deadline.
struct RoleLeaseOperationDeadline: Sendable {
  let instant: ContinuousClock.Instant
  private let now: @Sendable () -> ContinuousClock.Instant

  init(
    startedAt: ContinuousClock.Instant = .now,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
  ) {
    instant = startedAt.advanced(by: .seconds(3))
    self.now = now
  }

  func submit<Value>(_ operation: () throws -> Value) throws -> Value {
    try check()
    return try operation()
  }

  func check() throws {
    guard now() < instant else { throw RoleLeaseFailure.operationTimedOut }
  }
}
