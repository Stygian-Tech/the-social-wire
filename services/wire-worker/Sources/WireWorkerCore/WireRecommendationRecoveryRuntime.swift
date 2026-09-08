import Foundation
import Logging

enum WireRecommendationRecoveryRuntime {
  static func run(
    journal: any WireRecommendationRecovering,
    sourceScope: WireInboxSourceScope?,
    logger: Logger,
    clock: any WireInboxDrainClock = SystemWireInboxDrainClock(),
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    iterationLimit: Int? = nil
  ) async throws {
    var iterations = 0
    var lastBacklogAt: Date?
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      var delay = 5_000
      do {
        let now = await clock.now()
        let counts = try await journal.recover(
          asOf: now, limit: 16, sourceScope: sourceScope)
        if lastBacklogAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
          let backlog = try await journal.backlog(asOf: now, sourceScope: sourceScope)
          logger.info("The Wire deferred recommendation backlog", metadata: [
            "pending_count": .string("\(backlog.pendingCount)"),
            "conflict_count": .string("\(backlog.conflictCount)"),
            "oldest_pending_age_seconds": .string("\(backlog.oldestPendingAgeSeconds)"),
            "oldest_conflict_age_seconds": .string("\(backlog.oldestConflictAgeSeconds)"),
            "count_limit": .string("\(backlog.countLimit)"),
          ])
          lastBacklogAt = now
        }
        try Task.checkCancellation()
        if counts.attempted > 0 {
          logger.info(
            "The Wire recommendation recovery batch",
            metadata: [
              "attempted_count": .string("\(counts.attempted)"),
              "resolved_count": .string("\(counts.resolved)"),
              "pending_count": .string("\(counts.pending)"),
              "conflicted_count": .string("\(counts.conflicted)"),
              "superseded_count": .string("\(counts.superseded)"),
            ])
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Preserve all durable envelopes on failure. A slow dependency must not
        // hold the independent document/publication drain or create a retry storm.
        logger.error("The Wire recommendation recovery batch failed")
        delay = 30_000
      }
      iterations += 1
      try await sleeper.sleep(milliseconds: delay)
    }
    try Task.checkCancellation()
  }
}
