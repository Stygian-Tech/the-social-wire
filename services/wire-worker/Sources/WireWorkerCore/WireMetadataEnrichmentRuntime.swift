import Foundation
import Logging

enum WireMetadataEnrichmentRuntime {
  static func run(
    enricher: WireLinkMetadataEnricher,
    logger: Logger,
    idleMilliseconds: Int
  ) async throws -> Never {
    let boundedIdle = max(250, min(idleMilliseconds, 60_000))
    var nextHealthLogAt = Date.distantPast
    while true {
      do {
        let now = Date()
        let count = try await enricher.runBatch(asOf: now)
        if now >= nextHealthLogAt, let snapshot = try await enricher.healthSnapshot(asOf: now) {
          logger.info(
            "The Wire enrichment health",
            metadata: [
              "metadata_hits": .stringConvertible(snapshot.metadataHitCount),
              "metadata_stale": .stringConvertible(snapshot.metadataStaleCount),
              "metadata_misses": .stringConvertible(snapshot.metadataMissCount),
              "metadata_failures": .stringConvertible(snapshot.metadataFailureCount),
              "metadata_oldest_failure_seconds": .stringConvertible(snapshot.oldestFailureAgeSeconds),
              "people_eligible": .stringConvertible(snapshot.peopleEligibleCount),
              "people_profiles_fresh": .stringConvertible(snapshot.peopleFreshCount),
            ]
          )
          nextHealthLogAt = now.addingTimeInterval(60)
        }
        if count == 0 {
          try await Task.sleep(for: .milliseconds(boundedIdle))
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        logger.error("The Wire metadata runtime failed", metadata: ["error": .string("\(error)")])
        try await Task.sleep(for: .seconds(5))
      }
    }
  }

  static func runProfiles(
    enricher: WireTalkedAccountProfileEnricher,
    logger: Logger,
    idleMilliseconds: Int
  ) async throws -> Never {
    let boundedIdle = max(250, min(idleMilliseconds, 60_000))
    while true {
      do {
        let count = try await enricher.runBatch(asOf: Date())
        if count == 0 { try await Task.sleep(for: .milliseconds(boundedIdle)) }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        logger.error("The Wire people profile runtime failed", metadata: ["error": .string("\(error)")])
        try await Task.sleep(for: .seconds(5))
      }
    }
  }
}
