import Foundation

actor WireWorkerHealthState {
  private(set) var lastSuccessfulCycleAt: Date?
  private(set) var lastFailure: String?

  func recordSuccess(at: Date) {
    lastSuccessfulCycleAt = at
    lastFailure = nil
  }

  func recordFailure(_ error: Error) {
    lastFailure = String(reflecting: error)
  }

  func isReady(at now: Date, maximumCycleAge: TimeInterval) -> Bool {
    guard lastFailure == nil, let lastSuccessfulCycleAt else { return false }
    return now.timeIntervalSince(lastSuccessfulCycleAt) <= maximumCycleAge
  }
}
