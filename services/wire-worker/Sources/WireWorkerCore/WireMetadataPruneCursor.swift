import Foundation

/// Disposable progress shared by store copies. Recreating the hosted store resets the sweep.
actor WireMetadataPruneCursor {
  struct Position: Sendable, Equatable {
    // Preserve PostgreSQL's exact timestamp; Date round-trips can lose submicrosecond precision.
    let staleUntil: String
    let canonicalKey: String
  }

  struct Batch: Sendable {
    let position: Position?
    var examined: Int64 = 0
    var deleted: Int64 = 0
  }

  struct Report: Sendable {
    var examined: Int64 = 0
    var deleted: Int64 = 0
    var batches = 0
    var wrapped = false
    var duration: Duration = .zero
  }

  private var position: Position?
  private var running = false

  /// The operation must return only after commit. Errors (including uncertain commit outcomes)
  /// retain the old position so a retry cannot skip uncommitted work. Concurrent calls coalesce.
  func run(
    maximumBatches: Int = 20,
    timeBudget: Duration = .seconds(2),
    _ operation: @Sendable (Position?) async throws -> Batch
  ) async throws -> Report? {
    guard !running else { return nil }
    try Task.checkCancellation()
    running = true
    defer { running = false }
    let clock = ContinuousClock()
    let started = clock.now
    var report = Report()
    for _ in 0..<max(0, maximumBatches) {
      try Task.checkCancellation()
      guard started.duration(to: clock.now) < timeBudget else { break }
      let batch = try await operation(position)
      position = batch.position
      report.examined += batch.examined
      report.deleted += batch.deleted
      report.batches += 1
      // A short/empty page exhausts this sweep. Never begin another sweep in the same pass.
      if position == nil {
        report.wrapped = true
        break
      }
    }
    report.duration = started.duration(to: clock.now)
    return report.batches > 0 ? report : nil
  }
}
