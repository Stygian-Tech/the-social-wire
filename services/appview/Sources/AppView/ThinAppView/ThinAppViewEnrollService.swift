import AsyncHTTPClient
import GatewayCore
import Foundation
import GatewayCore
import Hummingbird
import Logging
import NIOCore
import ThinAppViewCore

actor ThinAppViewEnrollService {
  private let store: any ThinAppViewStore
  private let indexer: ThinAppViewIndexer
  private let httpClient: HTTPClient
  private let plcURL: String
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
    self.store = store
    self.indexer = indexer
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.config = config
    self.logger = logger
  }

  func enroll(auth: AuthContext, authorDids: [String]) async throws -> Int {
    let unique = Array(Set(authorDids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
      .prefix(config.maxEnrollAuthors)

    var indexed = 0
    for authorDid in unique {
      indexed += try await backfillAuthor(authorDid: authorDid)
    }

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

  private func backfillAuthor(authorDid: String) async throws -> Int {
    guard
      let pds = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: authorDid,
        plcBase: plcURL,
        httpClient: httpClient
      )
    else { return 0 }

    var total = 0
    for collection in ThinAppViewConfig.contentCollections {
      total += try await backfillCollection(
        authorDid: authorDid,
        pdsBase: pds,
        collection: collection
      )
    }
    return total
  }

  private func backfillCollection(
    authorDid: String,
    pdsBase: String,
    collection: String
  ) async throws -> Int {
    var cursor: String?
    var count = 0
    repeat {
      var params = [
        "repo": authorDid,
        "collection": collection,
        "limit": "50",
        "reverse": "true",
      ]
      if let cursor { params["cursor"] = cursor }

      let query = params.map { "\($0.key)=\(($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value))" }
        .joined(separator: "&")
      let url = "\(ATProtoPdsResolution.normalizePdsBase(pdsBase))/xrpc/com.atproto.repo.listRecords?\(query)"

      var request = HTTPClientRequest(url: url)
      request.headers.add(name: "Accept", value: "application/json")
      let response = try await httpClient.execute(request, timeout: .seconds(20))
      guard response.status == .ok else { break }

      let body = try await response.body.collect(upTo: 512 * 1024)
      guard
        let json = try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
        let records = json["records"] as? [[String: Any]]
      else { break }

      for row in records {
        guard
          let uri = row["uri"] as? String,
          let cid = row["cid"] as? String,
          let value = row["value"],
          let parsed = RenderFieldExtractor.parseAtUri(uri),
          JSONSerialization.isValidJSONObject(value),
          let recordJSON = try? JSONSerialization.data(withJSONObject: value)
        else { continue }

        try await indexer.handleCommit(
          repoDid: parsed.did,
          collection: parsed.collection,
          rkey: parsed.rkey,
          cid: cid,
          recordJSON: recordJSON,
          operation: "create",
          pdsBase: pdsBase
        )
        count += 1
      }

      cursor = json["cursor"] as? String
      if count >= 200 { break }
    } while cursor != nil

    return count
  }
}
