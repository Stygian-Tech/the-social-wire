import AsyncHTTPClient
import GatewayCore
import Foundation
import Hummingbird
import Logging
import ThinAppViewCore

actor ThinAppViewEnrollService {
  private let backfill: ThinAppViewEnrollBackfill
  private let config: ThinAppViewConfig
  private let logger: Logger

  init(
    store: any ThinAppViewStore,
    indexer: ThinAppViewIndexer,
    httpClient: HTTPClient,
    plcURL: String,
    config: ThinAppViewConfig,
    logger: Logger
  ) {
    self.backfill = ThinAppViewEnrollBackfill(
      store: store,
      indexer: indexer,
      httpClient: httpClient,
      plcURL: plcURL,
      config: config,
      logger: logger
    )
    self.config = config
    self.logger = logger
  }

  func enroll(auth: AuthContext, authorDids: [String]) async throws -> Int {
    let unique = Array(
      Set(authorDids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    )
    .prefix(config.maxEnrollAuthors)

    let indexed = try await backfill.enroll(authorDids: Array(unique))
    logger.info(
      "Enrollment backfill complete",
      metadata: [
        "viewer": .string(auth.did),
        "authors": .stringConvertible(unique.count),
        "records": .stringConvertible(indexed),
      ]
    )
    return indexed
  }
}
