import Foundation

/// Keeps daily history current even when no operator opens the console.
actor OperationsViewerHistoryCollector {
  private let collect: @Sendable (Date) async -> Void
  private let sleep: @Sendable (Duration) async throws -> Void
  private var isRunning = false

  init(
    collect: @escaping @Sendable (Date) async -> Void,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.collect = collect
    self.sleep = sleep
  }

  func runForever() async {
    guard !isRunning else { return }
    isRunning = true
    defer { isRunning = false }

    while !Task.isCancelled {
      await collect(Date())
      guard !Task.isCancelled else { return }
      do {
        try await sleep(.seconds(3_600))
      } catch {
        return
      }
    }
  }
}
