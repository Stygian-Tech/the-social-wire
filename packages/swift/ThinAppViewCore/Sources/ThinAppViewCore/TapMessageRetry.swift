import Foundation

enum TapMessageRetry {
  static let defaultDelays: [Duration] = [
    .milliseconds(250),
    .seconds(1),
    .seconds(2),
  ]

  static func run(
    delays: [Duration] = defaultDelays,
    operation: @Sendable () async throws -> Void
  ) async throws {
    var remainingDelays = delays.makeIterator()
    while true {
      do {
        try await operation()
        return
      } catch {
        guard let delay = remainingDelays.next() else { throw error }
        try await Task.sleep(for: delay)
      }
    }
  }
}
