import Foundation

public actor RedisCircuitBreaker {
  public enum State: Sendable, Equatable {
    case closed
    case open
    case halfOpen
  }

  private let failureThreshold: Int
  private let initialOpenDuration: TimeInterval
  private let maximumOpenDuration: TimeInterval
  private var consecutiveFailures = 0
  private var openCount = 0
  private var openedAt: Date?
  private var halfOpenProbeInFlight = false

  public init(
    failureThreshold: Int = 3,
    initialOpenDuration: TimeInterval = 5,
    maximumOpenDuration: TimeInterval = 30
  ) {
    self.failureThreshold = failureThreshold
    self.initialOpenDuration = initialOpenDuration
    self.maximumOpenDuration = maximumOpenDuration
  }

  public func state(at now: Date = Date()) -> State {
    guard let openedAt else { return .closed }
    if now.timeIntervalSince(openedAt) >= currentOpenDuration {
      return .halfOpen
    }
    return .open
  }

  public func permit(at now: Date = Date()) -> Bool {
    switch state(at: now) {
    case .closed:
      return true
    case .open:
      return false
    case .halfOpen:
      guard !halfOpenProbeInFlight else { return false }
      halfOpenProbeInFlight = true
      return true
    }
  }

  public func recordSuccess() {
    consecutiveFailures = 0
    openCount = 0
    openedAt = nil
    halfOpenProbeInFlight = false
  }

  public func recordFailure(at now: Date = Date()) {
    halfOpenProbeInFlight = false
    consecutiveFailures += 1
    if openedAt != nil || consecutiveFailures >= failureThreshold {
      openCount += 1
      openedAt = now
    }
  }

  private var currentOpenDuration: TimeInterval {
    min(initialOpenDuration * pow(2, Double(max(0, openCount - 1))), maximumOpenDuration)
  }
}
