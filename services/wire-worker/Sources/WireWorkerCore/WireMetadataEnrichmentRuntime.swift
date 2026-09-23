import Foundation
import Logging

enum WireMetadataEnrichmentRuntime {
  static func run(
    enricher: WireLinkMetadataEnricher,
    logger: Logger,
    idleMilliseconds: Int
  ) async throws -> Never {
    try await run(logger: logger, idleMilliseconds: idleMilliseconds,
      batch: { try await enricher.runBatch(asOf: Date()) },
      sleep: { try await Task.sleep(for: $0) })
  }

  static func run(
    logger: Logger, idleMilliseconds: Int,
    batch: @Sendable () async throws -> Int,
    sleep: @Sendable (Duration) async throws -> Void
  ) async throws -> Never {
    let boundedIdle = max(250, min(idleMilliseconds, 60_000))
    var failureDelay = 5
    while true {
      do {
        try Task.checkCancellation()
        let count = try await batch()
        failureDelay = 5
        if count == 0 {
          try await sleep(.milliseconds(boundedIdle))
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        logger.error("The Wire metadata runtime failed", metadata: ["error": .string("\(error)")])
        try await sleep(.seconds(failureDelay))
        failureDelay = min(60, failureDelay * 2)
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
