import Foundation

actor JetstreamReplayProgressMonitor {
  struct TimeoutError: Error, Equatable, Sendable {
    let lastObservedCursor: Int64
  }

  struct State: Equatable, Sendable {
    private(set) var greatestCursor: Int64
    private(set) var lastAdvancedAt: Date

    init(initialCursor: Int64, startedAt: Date) {
      greatestCursor = initialCursor
      lastAdvancedAt = startedAt
    }

    mutating func observe(cursor: Int64, at: Date) {
      guard cursor > greatestCursor else { return }
      greatestCursor = cursor
      lastAdvancedAt = at
    }

    func hasStalled(at: Date, timeout: TimeInterval) -> Bool {
      at.timeIntervalSince(lastAdvancedAt) >= timeout
    }
  }

  private let timeout: TimeInterval
  private let pollInterval: TimeInterval
  private var state: State

  init(
    initialCursor: Int64,
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.5,
    startedAt: Date = Date()
  ) {
    self.timeout = max(0.01, timeout)
    self.pollInterval = max(0.01, pollInterval)
    state = State(initialCursor: initialCursor, startedAt: startedAt)
  }

  func observe(cursor: Int64, at: Date = Date()) {
    state.observe(cursor: cursor, at: at)
  }

  func waitForStall() async throws -> Never {
    while true {
      try Task.checkCancellation()
      let now = Date()
      if state.hasStalled(at: now, timeout: timeout) {
        throw TimeoutError(lastObservedCursor: state.greatestCursor)
      }
      let remaining = timeout - now.timeIntervalSince(state.lastAdvancedAt)
      try await Task.sleep(for: .seconds(min(pollInterval, max(0.01, remaining))))
    }
  }
}
