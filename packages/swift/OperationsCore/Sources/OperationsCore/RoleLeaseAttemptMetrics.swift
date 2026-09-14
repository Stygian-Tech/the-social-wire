import Foundation

/// Shared only by an attempt and its cancellation/measurement callbacks.
final class RoleLeaseAttemptMetrics: @unchecked Sendable {
  @TaskLocal static var current: RoleLeaseAttemptMetrics?
  private let lock = NSLock()
  private var poolWait: Double?
  private var database: Double?

  func record(poolWait: Double? = nil, database: Double? = nil) {
    lock.withLock {
      if let poolWait { self.poolWait = poolWait }
      if let database { self.database = database }
    }
  }
  var snapshot: (poolWait: Double?, database: Double?) {
    lock.withLock { (poolWait, database) }
  }
}
