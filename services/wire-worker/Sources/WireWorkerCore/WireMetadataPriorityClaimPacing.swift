import Foundation

/// Shared by store copies; general work continues while expensive priority work cools down.
actor WireMetadataPriorityClaimPacing {
  private var inFlight = false
  private var retryAt: ContinuousClock.Instant?
  private var delaySeconds = 5

  func begin(now: ContinuousClock.Instant = .now) -> Bool {
    guard !inFlight, retryAt.map({ now >= $0 }) ?? true else { return false }
    inFlight = true
    return true
  }

  func succeeded() {
    inFlight = false
    retryAt = nil
    delaySeconds = 5
  }

  func failed(now: ContinuousClock.Instant = .now) {
    inFlight = false
    retryAt = now.advanced(by: .seconds(delaySeconds))
    delaySeconds = min(60, delaySeconds * 2)
  }
}
