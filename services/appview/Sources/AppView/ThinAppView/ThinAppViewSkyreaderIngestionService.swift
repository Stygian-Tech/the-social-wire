import Foundation
import GatewayCore
import Logging
import ThinAppViewCore

actor ThinAppViewSkyreaderIngestionService {
  private let repo: ATProtoAuthenticatedRepoClient
  private let rssIngestion: ThinAppViewRssIngestion
  private let logger: Logger

  init(
    repo: ATProtoAuthenticatedRepoClient,
    rssIngestion: ThinAppViewRssIngestion,
    logger: Logger
  ) {
    self.repo = repo
    self.rssIngestion = rssIngestion
    self.logger = logger
  }

  func ingestViewerSubscriptions(
    auth: AuthContext,
    priorityFeedUrls: [String] = []
  ) async throws -> Int {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.skyreaderFeedSubscription,
      maxPages: 20
    )
    var feedUrls: [String] = []
    var seen = Set<String>()
    for record in records {
      guard let url = ThinAppViewRssIngestion.feedUrl(fromSubscriptionRecord: record.value.values) else {
        continue
      }
      guard seen.insert(url).inserted else { continue }
      feedUrls.append(url)
    }

    let priority = priorityFeedUrls.compactMap { RssFeedIdentity.normalizeFeedUrl($0) }
    var ordered: [String] = []
    var orderedSeen = Set<String>()
    for url in priority + feedUrls {
      guard orderedSeen.insert(url).inserted else { continue }
      ordered.append(url)
    }

    var total = 0
    for url in ordered {
      total += try await rssIngestion.ingestFeed(normalizedFeedUrl: url)
    }

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
}
