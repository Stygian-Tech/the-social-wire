import Foundation

/// Disposable progress shared by store copies. A restarted process safely repeats a sweep.
actor WireMetadataPruneCursor {
  struct Position: Sendable, Equatable {
    // Preserve PostgreSQL's exact timestamp; Date round-trips can lose submicrosecond precision.
    let staleUntil: String
    let canonicalKey: String
  }

  private var position: Position?
  private var running = false

  /// The operation must return only after commit. Errors (including uncertain commit outcomes)
  /// retain the old position so a retry cannot skip uncommitted work. Concurrent calls coalesce.
  func run(
    maximumBatches: Int = 20,
    timeBudget: Duration = .seconds(2),
    _ operation: @Sendable (Position?) async throws -> Position?
  ) async throws {
    guard !running else { return }
    try Task.checkCancellation()
    running = true
    defer { running = false }
    let clock = ContinuousClock()
    let started = clock.now
    for _ in 0..<max(0, maximumBatches) {
      try Task.checkCancellation()
      guard started.duration(to: clock.now) < timeBudget else { break }
      position = try await operation(position)
      // A short/empty page exhausts this sweep. Never begin another sweep in the same pass.
      if position == nil { break }
    }
  }
}
