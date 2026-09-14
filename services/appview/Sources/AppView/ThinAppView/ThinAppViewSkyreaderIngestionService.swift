import Foundation
import GatewayCore
import Logging
import ThinAppViewCore

actor ThinAppViewSkyreaderIngestionService {
  private let viewerFeedUrls: @Sendable (AuthContext) async throws -> [String]
  private let ingestFeed: @Sendable (String) async throws -> Int
  private let logger: Logger

  init(
    repo: ATProtoAuthenticatedRepoClient,
    rssIngestion: ThinAppViewRssIngestion,
    logger: Logger
  ) {
    self.viewerFeedUrls = { auth in
      let records = try await repo.listAllRecords(
        auth: auth,
        repo: auth.did,
        collection: PublicationLexicons.skyreaderFeedSubscription,
        maxPages: 20
      )
      return records.compactMap {
        ThinAppViewRssIngestion.feedUrl(fromSubscriptionRecord: $0.value.values)
      }
    }
    self.ingestFeed = { try await rssIngestion.ingestFeed(normalizedFeedUrl: $0) }
    self.logger = logger
  }

  init(
    viewerFeedUrls: @escaping @Sendable (AuthContext) async throws -> [String],
    ingestFeed: @escaping @Sendable (String) async throws -> Int,
    logger: Logger
  ) {
    self.viewerFeedUrls = viewerFeedUrls
    self.ingestFeed = ingestFeed
    self.logger = logger
  }

  /// Warm only the selected publications. Full subscription discovery belongs to background warming.
  func ingestSelectedFeeds(feedUrls: [String]) async throws -> Int {
    try await ingestOrderedFeeds(Self.normalizedUniqueFeedUrls(feedUrls))
  }

  func ingestViewerSubscriptions(
    auth: AuthContext,
    priorityFeedUrls: [String] = []
  ) async throws -> Int {
    try Task.checkCancellation()
    let feedUrls = try await viewerFeedUrls(auth)
    // Subscription URLs were normalized during record decoding; preserve their existing identity.
    let ordered = Self.uniqueFeedUrls(
      priorityFeedUrls.compactMap { RssFeedIdentity.normalizeFeedUrl($0) } + feedUrls
    )
    let total = try await ingestOrderedFeeds(ordered)

    if total > 0 {
      logger.info(
        "Indexed viewer Skyreader subscriptions",
        metadata: [
          "viewer": .string(auth.did),
          "feeds": .stringConvertible(ordered.count),
          "items": .stringConvertible(total),
        ]
      )
    }
    return total
  }

  private func ingestOrderedFeeds(_ feedUrls: [String]) async throws -> Int {
    try Task.checkCancellation()
    var total = 0
    for url in feedUrls {
      try Task.checkCancellation()
      total += try await ingestFeed(url)
      try Task.checkCancellation()
    }
    return total
  }

  private static func normalizedUniqueFeedUrls(_ feedUrls: [String]) -> [String] {
    uniqueFeedUrls(feedUrls.compactMap { RssFeedIdentity.normalizeFeedUrl($0) })
  }

  private static func uniqueFeedUrls(_ feedUrls: [String]) -> [String] {
    var seen = Set<String>()
    return feedUrls.filter { seen.insert($0).inserted }
  }
}
