import Foundation
import Logging

/// Logging-only corpus scans have their own serial, cancelable cadence under
/// the Coordinator's existing task group. Neither failure nor slow collection
/// starts a catch-up run or blocks the metadata fetch loop.
enum WireEnrichmentHealthRuntime {
  static func run(
    store: any WireLinkMetadataStoring,
    logger: Logger,
    clock: any WireInboxDrainClock = SystemWireInboxDrainClock(),
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    iterationLimit: Int? = nil
  ) async throws {
    var iterations = 0
    // Keep full-corpus diagnostics out of the initial publication/ingestion wave.
    try await sleeper.sleep(milliseconds: 60_000)
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      try Task.checkCancellation()
      let observedAt = await clock.now()
      do {
        let snapshot = try await store.healthSnapshot(asOf: observedAt)
        try Task.checkCancellation()
        if let snapshot {
          logger.info("The Wire enrichment health", metadata: [
            "observed_at": .string(observedAt.ISO8601Format()),
            "available": "true",
            "metadata_hits": .stringConvertible(snapshot.metadataHitCount),
            "metadata_stale": .stringConvertible(snapshot.metadataStaleCount),
            "metadata_misses": .stringConvertible(snapshot.metadataMissCount),
            "metadata_failures": .stringConvertible(snapshot.metadataFailureCount),
            "metadata_oldest_failure_seconds": .stringConvertible(snapshot.oldestFailureAgeSeconds),
            "people_eligible": .stringConvertible(snapshot.peopleEligibleCount),
            "people_profiles_fresh": .stringConvertible(snapshot.peopleFreshCount),
          ])
        } else {
          logger.info("The Wire enrichment health unavailable", metadata: [
            "attempted_at": .string(observedAt.ISO8601Format()), "available": "false",
          ])
        }
      } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        logger.warning("The Wire enrichment health unavailable", metadata: [
          "attempted_at": .string(observedAt.ISO8601Format()), "available": "false",
          "failure_category": "collection_failed",
        ])
      }
      iterations += 1
      // Delay from completion on success, nil and failure alike. This is a minimum
      // 15-minute interval; slow collection never produces catch-up bursts.
      try await sleeper.sleep(milliseconds: 900_000)
    }
  }
}
