import AsyncHTTPClient
import Foundation
import Logging

/// Periodically re-backfills authors already present in the index to fill firehose gaps and deepen history.
public struct ThinAppViewProactiveBackfillJob: Sendable {
  private let store: any ThinAppViewStore
  private let backfill: ThinAppViewEnrollBackfill
  private let config: ThinAppViewConfig
  private let logger: Logger
  private let extraAuthorDids: [String]

  public init(
    store: any ThinAppViewStore,
    backfill: ThinAppViewEnrollBackfill,
    config: ThinAppViewConfig,
    logger: Logger,
    extraAuthorDids: [String] = []
  ) {
    self.store = store
    self.backfill = backfill
    self.config = config
    self.logger = logger
    self.extraAuthorDids = extraAuthorDids
  }

  public func runForever() async {
    guard config.proactiveBackfillEnabled else {
      logger.info("Proactive AppView backfill disabled")
      return
    }

    logger.info(
      "Starting proactive AppView backfill loop",
      metadata: [
        "intervalSeconds": .stringConvertible(Int(config.proactiveBackfillIntervalSeconds)),
        "authorLimit": .stringConvertible(config.proactiveBackfillAuthorLimit),
      ]
    )

    while !Task.isCancelled {
      await runOnce()
      do {
        try await Task.sleep(for: .seconds(config.proactiveBackfillIntervalSeconds))
      } catch {
        return
      }
    }
  }

  func runOnce() async {
    var authorDids: [String] = extraAuthorDids
    do {
      let indexedAuthors = try await store.listAuthorDidsForProactiveBackfill(
        limit: config.proactiveBackfillAuthorLimit
      )
      authorDids.append(contentsOf: indexedAuthors)
    } catch {
      logger.warning(
        "Proactive backfill author lookup failed",
        metadata: ["error": .string(String(describing: error))]
      )
    }

    let unique = Array(
      Set(authorDids.filter(ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(_:)))
    )
    guard !unique.isEmpty else { return }

    do {
      let indexed = try await backfill.enroll(authorDids: unique)
      logger.info(
        "Proactive AppView backfill finished",
        metadata: [
          "authors": .stringConvertible(unique.count),
          "records": .stringConvertible(indexed),
        ]
      )
    } catch {
      logger.warning(
        "Proactive AppView backfill failed",
        metadata: ["error": .string(String(describing: error))]
      )
    }
  }
}
