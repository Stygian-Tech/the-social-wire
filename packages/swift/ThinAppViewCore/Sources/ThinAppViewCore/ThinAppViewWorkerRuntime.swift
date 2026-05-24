import AsyncHTTPClient
import Foundation
import Logging

/// Runs firehose ingestion, proactive PDS backfill, and TTL cleanup until one task exits or throws.
public enum ThinAppViewWorkerRuntime {
  public static func run(
    store: any ThinAppViewStore,
    config: ThinAppViewConfig,
    logger: Logger,
    httpClient: HTTPClient? = nil,
    plcURL: String? = nil,
    proactiveExtraAuthorDids: [String] = [],
    projectionCache: (any AppViewProjectionCacheStore)? = nil
  ) async throws {
    let indexer = ThinAppViewIndexer(
      store: store,
      config: config,
      logger: logger,
      httpClient: httpClient,
      plcURL: plcURL,
      rssIngestion: httpClient.map {
        ThinAppViewRssIngestion(store: store, httpClient: $0, config: config, logger: logger)
      },
      projectionCache: projectionCache
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

      if config.proactiveBackfillEnabled, let httpClient, let plcURL {
        let backfill = ThinAppViewEnrollBackfill(
          store: store,
          indexer: indexer,
          httpClient: httpClient,
          plcURL: plcURL,
          config: config,
          logger: logger
        )
        let proactive = ThinAppViewProactiveBackfillJob(
          store: store,
          backfill: backfill,
          config: config,
          logger: logger,
          extraAuthorDids: proactiveExtraAuthorDids
        )
        group.addTask { await proactive.runForever() }
      }

      if config.rssFeedPollEnabled, let httpClient {
        let rssIngestion = ThinAppViewRssIngestion(
          store: store,
          httpClient: httpClient,
          config: config,
          logger: logger
        )
        let rssPoll = ThinAppViewRssFeedPollJob(
          store: store,
          rssIngestion: rssIngestion,
          config: config,
          logger: logger
        )
        group.addTask { await rssPoll.runForever() }
      }

      try await group.next()
      group.cancelAll()
    }
  }
}
