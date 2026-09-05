import Foundation

/// Collects database costs even when no operator has the overview open.
actor OperationsDatabaseCostCollector {
  private let collect: @Sendable (Date) async -> Void
  private let now: @Sendable () -> ContinuousClock.Instant
  private let sleep: @Sendable (Duration) async throws -> Void
  private var isRunning = false

  init(
    collect: @escaping @Sendable (Date) async -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.collect = collect
    self.now = now
    self.sleep = sleep
  }

  func runForever() async {
    guard !isRunning else { return }
    isRunning = true
    defer { isRunning = false }

    while !Task.isCancelled {
      let started = now()
      await collect(Date())
      guard !Task.isCancelled else { return }
      // Include query/export time in the minute. A slow pass finishes before the next
      // starts; missed intervals never enqueue concurrent work or catch-up samples.
      let remaining = max(.zero, .seconds(60) - started.duration(to: now()))
      do {
        try await sleep(remaining)
      } catch {
        return
      }
    }
  }
}
