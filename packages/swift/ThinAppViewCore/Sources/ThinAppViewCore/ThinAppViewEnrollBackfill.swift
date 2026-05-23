import AsyncHTTPClient
import Foundation
import Logging

/// PDS listRecords backfill into the thin AppView index (shared by AppView enroll and the worker).
public struct ThinAppViewEnrollBackfill: Sendable {
  private let store: any ThinAppViewStore
  private let indexer: ThinAppViewIndexer
  private let httpClient: HTTPClient
  private let plcURL: String
  private let config: ThinAppViewConfig
  private let logger: Logger

  public init(
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

  /// When `recentOnly` is true, fetches only the newest page per collection (fast client refresh).
  public func enroll(authorDids: [String], recentOnly: Bool = false) async throws -> Int {
    let unique = Array(
      Set(
        authorDids
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter(Self.isBackfillEligibleAuthorDid)
      )
    )
    .prefix(config.maxEnrollAuthors)

    guard !unique.isEmpty else { return 0 }

    var indexed = 0
    var iterator = unique.makeIterator()

    try await withThrowingTaskGroup(of: Int.self) { group in
      var inFlight = 0

      func enqueueNext() {
        guard inFlight < config.maxEnrollConcurrency, let authorDid = iterator.next() else { return }
        inFlight += 1
        group.addTask {
          try await self.backfillAuthor(authorDid: authorDid, recentOnly: recentOnly)
        }
      }

      for _ in 0..<config.maxEnrollConcurrency {
        enqueueNext()
      }

      while inFlight > 0 {
        indexed += try await group.next() ?? 0
        inFlight -= 1
        enqueueNext()
      }
    }

    logger.info(
      "Enrollment backfill complete",
      metadata: [
        "authors": .stringConvertible(unique.count),
        "records": .stringConvertible(indexed),
      ]
    )
    return indexed
  }

  public static func isBackfillEligibleAuthorDid(_ raw: String) -> Bool {
    guard !raw.isEmpty, raw.hasPrefix("did:") else { return false }
    if raw.hasPrefix("did:web:") { return false }
    return true
  }

  private func backfillAuthor(authorDid: String, recentOnly: Bool) async throws -> Int {
    guard
      let pds = try await ThinAppViewPdsResolution.resolvePdsBase(
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
        collection: collection,
        recentOnly: recentOnly
      )
    }
    return total
  }

  private func backfillCollection(
    authorDid: String,
    pdsBase: String,
    collection: String,
    recentOnly: Bool
  ) async throws -> Int {
    var cursor: String?
    var count = 0
    let recordCap = config.maxEnrollRecordsPerAuthor
    repeat {
      var params = [
        "repo": authorDid,
        "collection": collection,
        "limit": "50",
        "reverse": "true",
      ]
      if let cursor { params["cursor"] = cursor }

      let query = params
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
        .joined(separator: "&")
      let url = "\(normalizePdsBase(pdsBase))/xrpc/com.atproto.repo.listRecords?\(query)"

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
      if recentOnly { break }
      if count >= recordCap { break }
    } while cursor != nil

    return count
  }

  private func normalizePdsBase(_ raw: String) -> String {
    var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    return base
  }
}
