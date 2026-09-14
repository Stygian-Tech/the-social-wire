import Foundation
import Logging

/// Runs only in the Coordinator's existing materializer lifetime, sharing its pool.
enum WireRecommendationHydrationRuntime {
  static func run(
    hydrator: WireRecommendationHydrator, snapshots: PostgresWireInboxProcessor, logger: Logger,
    clock: any WireInboxDrainClock = SystemWireInboxDrainClock(),
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(), iterationLimit: Int? = nil
  ) async throws {
    var iterations = 0
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      var delay = 5_000
      do {
        let now = await clock.now()
        // Restore abandoned internal snapshot claims after process/lease loss.
        // This bounded lane finishes before starting the two network hydration slots.
        let claims = try await snapshots.claimWork(asOf: now, limit: 2)
        for event in claims.events {
          _ = try await snapshots.applyClaimed(event, asOf: await clock.now())
        }
        let counts = try await hydrator.hydrate(asOf: await clock.now(), limit: 16)
        _ = try await snapshots.deleteTerminal(asOf: await clock.now(), batchSize: 250)
        if counts.attempted > 0 || !claims.events.isEmpty {
          logger.info("The Wire automatic dependency recovery batch", metadata: [
            "attempted_count": .stringConvertible(counts.attempted),
            "verified_count": .stringConvertible(counts.verified),
            "staged_snapshot_count": .stringConvertible(counts.staged),
            "unavailable_count": .stringConvertible(counts.unavailable),
            "superseded_count": .stringConvertible(counts.superseded),
            "reclaimed_snapshot_count": .stringConvertible(claims.events.count),
          ])
          delay = 1_000
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        logger.error("The Wire automatic dependency recovery failed; durable work retained")
        delay = 30_000
      }
      iterations += 1
      try await sleeper.sleep(milliseconds: delay)
    }
    try Task.checkCancellation()
  }
}
