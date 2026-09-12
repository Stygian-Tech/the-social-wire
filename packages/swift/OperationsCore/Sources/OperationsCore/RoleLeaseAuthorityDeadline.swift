import Foundation

/// Monotonic authority can only advance following a confirmed, timely database grant.
actor RoleLeaseAuthorityDeadline {
  private var deadline: TimeInterval
  init(deadline: TimeInterval) { self.deadline = deadline }

  func remaining(at now: TimeInterval) -> TimeInterval { max(0, deadline - now) }

  func check(at now: TimeInterval) throws {
    guard now < deadline else { throw RoleLeaseFailure.authorityExpired }
  }

  func confirm(deadline next: TimeInterval, at now: TimeInterval) throws {
    try check(at: now)
    guard next > now else { throw RoleLeaseFailure.authorityExpired }
    deadline = next
  }
}
