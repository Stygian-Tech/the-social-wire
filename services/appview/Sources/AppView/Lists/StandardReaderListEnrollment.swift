import Foundation

/// A cold list cannot claim an empty corpus until its bounded initial backfill has finished.
actor StandardReaderListEnrollment {
  private let limiter = StandardReaderPreparationLimiter()
  private var completedUntil: [String: Date] = [:]
  private var inFlight: [String: Task<Void, Never>] = [:]

  func begin(key: String, operation: @escaping @Sendable () async throws -> Void) -> Bool {
    if let until = completedUntil[key], until > Date() { return true }
    if inFlight[key] == nil {
      inFlight[key] = Task {
        await self.limiter.acquire()
        do {
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
              try await Task.sleep(for: .seconds(60))
              throw EnrollmentDeadlineExceeded()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
          }
          self.completedUntil[key] = Date().addingTimeInterval(300)
        } catch {
          // A failed backfill remains retryable and never manufactures an authoritative empty page.
        }
        await self.limiter.release()
        self.inFlight[key] = nil
      }
    }
    return false
  }

  private struct EnrollmentDeadlineExceeded: Error {}

  func waitForCurrent(key: String) async { await inFlight[key]?.value }

  static func shouldWarm(empty: Bool, enrollmentComplete: Bool) -> Bool {
    empty && !enrollmentComplete
  }
}
