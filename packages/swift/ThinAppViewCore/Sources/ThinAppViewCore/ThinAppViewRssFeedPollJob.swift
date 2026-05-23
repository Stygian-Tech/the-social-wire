import Foundation
import Logging

/// Periodically refreshes indexed Skyreader RSS feeds (stalest `indexed_at` first).
public struct ThinAppViewRssFeedPollJob: Sendable {
  private let store: any ThinAppViewStore
  private let rssIngestion: ThinAppViewRssIngestion
  private let config: ThinAppViewConfig
  private let logger: Logger

  public init(
    store: any ThinAppViewStore,
    rssIngestion: ThinAppViewRssIngestion,
    config: ThinAppViewConfig,
    logger: Logger
  ) {
    self.store = store
    self.rssIngestion = rssIngestion
    self.config = config
    self.logger = logger
  }

  public func runForever() async {
    guard config.rssFeedPollEnabled else { return }
    while !Task.isCancelled {
      do {
        try await pollOnce()
      } catch {
        logger.warning(
          "RSS feed poll failed",
          metadata: ["error": .string(String(describing: error))]
        )
      }
      try? await Task.sleep(for: .seconds(config.rssFeedPollIntervalSeconds))
    }
  }

  func pollOnce() async throws {
    let feedUrls = try await store.listRssPublicationSites(limit: config.rssFeedPollFeedLimit)
    guard !feedUrls.isEmpty else { return }
    var total = 0
    for feedUrl in feedUrls {
      total += try await rssIngestion.ingestFeed(normalizedFeedUrl: feedUrl)
    }
    logger.info(
      "RSS feed poll complete",
      metadata: [
        "feeds": .stringConvertible(feedUrls.count),
        "items": .stringConvertible(total),
      ]
    )
  }
}
