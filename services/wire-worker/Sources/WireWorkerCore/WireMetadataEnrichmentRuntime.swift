import Foundation
import Logging

enum WireMetadataEnrichmentRuntime {
  static func run(
    enricher: WireLinkMetadataEnricher,
    logger: Logger,
    idleMilliseconds: Int
  ) async throws -> Never {
    let boundedIdle = max(250, min(idleMilliseconds, 60_000))
    while true {
      do {
        let now = Date()
        let count = try await enricher.runBatch(asOf: now)
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
