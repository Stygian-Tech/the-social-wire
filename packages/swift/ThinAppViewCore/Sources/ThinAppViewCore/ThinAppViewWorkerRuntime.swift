import AsyncHTTPClient
import Foundation
import Logging

/// Runs firehose ingestion and TTL cleanup until one task exits or throws.
public enum ThinAppViewWorkerRuntime {
  public static func run(
    store: any ThinAppViewStore,
    config: ThinAppViewConfig,
    logger: Logger,
    httpClient: HTTPClient? = nil,
    plcURL: String? = nil
  ) async throws {
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      httpClient: httpClient,
      plcURL: plcURL
    )
    let firehose = FirehoseSubscriber(
      relayURL: config.relayWebSocketURL,
      indexer: indexer,
      logger: logger
    )
    let cleanup = ThinAppViewTtlCleanupJob(store: store, config: config, logger: logger)

    logger.info("Starting thin AppView worker")

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await firehose.runForever() }
      group.addTask { await cleanup.runForever() }
      try await group.next()
      group.cancelAll()
    }
  }
}
