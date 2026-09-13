import Foundation
import Logging

/// Disposable expiry work must not block ranking publication. Each store call
/// bounds each source to 500 rows and releases its transaction before the next.
enum WireDisposableCacheMaintenanceRuntime {
  static func run(
    store: any WireTalkedAccountMentionStoring,
    logger: Logger,
    sleeper: any WireInboxDrainSleeping = SystemWireInboxDrainSleeper(),
    iterationLimit: Int? = nil
  ) async throws {
    var iterations = 0
    // Avoid launching another scan in the first wave after ownership changes.
    try await sleeper.sleep(milliseconds: 10_000)
    while !Task.isCancelled, iterationLimit.map({ iterations < $0 }) ?? true {
      var delay = 10_000
      do {
        try Task.checkCancellation()
        try await store.pruneExpired(asOf: Date())
        try Task.checkCancellation()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        logger.warning("The Wire disposable cache cleanup failed", metadata: [
          "failure_category": "cleanup_failed", "retry_milliseconds": "30000",
        ])
        delay = 30_000
      }
      iterations += 1
      try await sleeper.sleep(milliseconds: delay)
    }
  }
}
