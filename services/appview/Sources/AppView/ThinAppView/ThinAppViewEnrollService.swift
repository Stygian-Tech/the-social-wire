import AsyncHTTPClient
import GatewayCore
import Foundation
import Hummingbird
import Logging
import ThinAppViewCore

actor ThinAppViewEnrollService {
  private let backfill: ThinAppViewEnrollBackfill
  private let skyreaderIngestion: ThinAppViewSkyreaderIngestionService?
  private let config: ThinAppViewConfig
  private let logger: Logger

  init(
    store: any ThinAppViewStore,
    indexer: ThinAppViewIndexer,
    httpClient: HTTPClient,
    plcURL: String,
    config: ThinAppViewConfig,
    logger: Logger,
    skyreaderIngestion: ThinAppViewSkyreaderIngestionService? = nil
  ) {
    self.backfill = ThinAppViewEnrollBackfill(
      store: store,
      indexer: indexer,
      httpClient: httpClient,
      plcURL: plcURL,
      config: config,
      logger: logger
    )
    self.skyreaderIngestion = skyreaderIngestion
    self.config = config
    self.logger = logger
  }

  func enroll(
    auth: AuthContext,
    authorDids: [String],
    feedUrls: [String] = [],
    recentOnly: Bool = true
  ) async throws -> Int {
    let uniqueAuthors = Array(
      Set(authorDids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    )
    .prefix(config.maxEnrollAuthors)

    var indexed = 0
    if !uniqueAuthors.isEmpty {
      indexed += try await backfill.enroll(
        authorDids: Array(uniqueAuthors),
        recentOnly: recentOnly
      )
    }

    let priorityFeedUrls = feedUrls
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if let skyreaderIngestion, !priorityFeedUrls.isEmpty {
      indexed += try await skyreaderIngestion.ingestViewerSubscriptions(
        auth: auth,
        priorityFeedUrls: priorityFeedUrls
      )
    }

    logger.info(
      "Enrollment backfill complete",
      metadata: [
        "viewer": .string(auth.did),
        "authors": .stringConvertible(uniqueAuthors.count),
        "feeds": .stringConvertible(priorityFeedUrls.count),
        "records": .stringConvertible(indexed),
      ]
    )
    return indexed
  }
}
