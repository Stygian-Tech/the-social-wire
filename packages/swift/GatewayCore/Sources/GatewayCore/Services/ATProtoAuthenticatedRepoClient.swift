import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import NIOCore
import ThinAppViewCore

/// JSON record payload safe to pass across Swift 6 concurrency domains.
public struct PdsRecordJSON: @unchecked Sendable {
  public let values: [String: Any]

  public init(values: [String: Any]) {
    self.values = values
  }
}

/// OAuth-forwarding XRPC client for the authenticated viewer's PDS and public author repos.
public actor ATProtoAuthenticatedRepoClient {
  private let httpClient: HTTPClient
  private let plcURL: String
  private let logger: Logger

  public init(httpClient: HTTPClient, plcURL: String, logger: Logger) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.logger = logger
  }

  public struct RepoRecord: Sendable {
    public let uri: String
    public let cid: String?
    public let value: PdsRecordJSON
  }

  public func listRecords(
    auth: AuthContext?,
    repo: String,
    collection: String,
    limit: Int = 50,
    cursor: String? = nil,
    reverse: Bool = true
  ) async throws -> (records: [RepoRecord], cursor: String?) {
    guard
      let repoDid = try await ATProtoPdsResolution.resolveRepoDid(
        handleOrDid: repo,
        httpClient: httpClient
      )
    else {
      return ([], nil)
    }

    guard
      let pdsBase = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: repoDid,
        plcBase: plcURL,
        httpClient: httpClient
      )
    else {
      return ([], nil)
    }

    let serverReverse =
      reverse && !ATProtoPdsResolution.relayHostOmitsListRecordsReverse(pdsBase: pdsBase)
    let sortPageNewestFirst = reverse && !serverReverse

    var queryItems = [
      URLQueryItem(name: "repo", value: repoDid),
      URLQueryItem(name: "collection", value: collection),
      URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
      URLQueryItem(name: "reverse", value: serverReverse ? "true" : "false"),
    ]
    if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }

    guard var comps = URLComponents(string: "\(ATProtoPdsResolution.normalizePdsBase(pdsBase))/xrpc/com.atproto.repo.listRecords") else {
      return ([], nil)
    }
    comps.queryItems = queryItems
    guard let url = comps.url?.absoluteString else { return ([], nil) }

    let json = try await executeJSON(url: url, auth: auth)
    var records = (json["records"] as? [[String: Any]]) ?? []
    if sortPageNewestFirst {
      records = Self.sortRecordsNewestFirst(records)
    }

    let mapped: [RepoRecord] = records.compactMap { row in
      guard let uri = row["uri"] as? String, let value = row["value"] as? [String: Any] else {
        return nil
      }
      return RepoRecord(uri: uri, cid: row["cid"] as? String, value: PdsRecordJSON(values: value))
    }
    return (mapped, json["cursor"] as? String)
  }

  public func listAllRecords(
    auth: AuthContext?,
    repo: String,
    collection: String,
    pageLimit: Int = 50,
    maxPages: Int = 20
  ) async throws -> [RepoRecord] {
    var all: [RepoRecord] = []
    var cursor: String?
    var pages = 0
    repeat {
      let page = try await listRecords(
        auth: auth,
        repo: repo,
        collection: collection,
        limit: pageLimit,
        cursor: cursor,
        reverse: true
      )
      all.append(contentsOf: page.records)
      cursor = page.cursor
      pages += 1
    } while cursor != nil && pages < maxPages
    return all
  }

  public func getRecord(
    auth: AuthContext?,
    repo: String,
    collection: String,
    rkey: String
  ) async throws -> PdsRecordJSON? {
    guard
      let repoDid = try await ATProtoPdsResolution.resolveRepoDid(
        handleOrDid: repo,
        httpClient: httpClient
      )
    else { return nil }

    guard
      let pdsBase = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: repoDid,
        plcBase: plcURL,
        httpClient: httpClient
      )
    else { return nil }

    guard var comps = URLComponents(string: "\(ATProtoPdsResolution.normalizePdsBase(pdsBase))/xrpc/com.atproto.repo.getRecord") else {
      return nil
    }
    comps.queryItems = [
      URLQueryItem(name: "repo", value: repoDid),
      URLQueryItem(name: "collection", value: collection),
      URLQueryItem(name: "rkey", value: rkey),
    ]
    guard let url = comps.url?.absoluteString else { return nil }

    let json = try await executeJSON(url: url, auth: auth)
    guard let value = json["value"] as? [String: Any] else { return nil }
    return PdsRecordJSON(values: value)
  }

  public func getRecordByAtUri(auth: AuthContext?, atUri: String) async throws -> PdsRecordJSON? {
    guard let parsed = RenderFieldExtractor.parseAtUri(AtUriNormalization.normalizeAtRepoParam(atUri)) else {
      return nil
    }
    return try await getRecord(
      auth: auth,
      repo: parsed.did,
      collection: parsed.collection,
      rkey: parsed.rkey
    )
  }

  public func createRecord(
    auth: AuthContext,
    collection: String,
    record: [String: Any]
  ) async throws -> String? {
    try await mutateRecord(
      auth: auth,
      method: "com.atproto.repo.createRecord",
      body: [
        "repo": auth.did,
        "collection": collection,
        "record": record,
      ]
    )?["uri"] as? String
  }

  public func putRecord(
    auth: AuthContext,
    collection: String,
    rkey: String,
    record: [String: Any]
  ) async throws {
    _ = try await mutateRecord(
      auth: auth,
      method: "com.atproto.repo.putRecord",
      body: [
        "repo": auth.did,
        "collection": collection,
        "rkey": rkey,
        "record": record,
      ]
    )
  }

  public func deleteRecord(
    auth: AuthContext,
    collection: String,
    rkey: String
  ) async throws {
    _ = try await mutateRecord(
      auth: auth,
      method: "com.atproto.repo.deleteRecord",
      body: [
        "repo": auth.did,
        "collection": collection,
        "rkey": rkey,
      ]
    )
  }

  // MARK: - Private

  private func mutateRecord(
    auth: AuthContext,
    method: String,
    body: [String: Any]
  ) async throws -> [String: Any]? {
    guard
      let pdsBase = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: auth.did,
        plcBase: plcURL,
        httpClient: httpClient
      )
    else { return nil }

    let url = "\(ATProtoPdsResolution.normalizePdsBase(pdsBase))/xrpc/\(method)"
    var request = HTTPClientRequest(url: url)
    request.method = .POST
    request.headers.add(name: "Accept", value: "application/json")
    request.headers.add(name: "Content-Type", value: "application/json")
    let payload = auth.authorizationForwardingValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !payload.isEmpty {
      request.headers.add(name: "Authorization", value: payload)
    }
    if let dpop = auth.dpopProof?.trimmingCharacters(in: .whitespacesAndNewlines), !dpop.isEmpty {
      request.headers.add(name: "DPoP", value: dpop)
    }
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    request.body = .bytes(ByteBuffer(data: bodyData))

    let reply = try await httpClient.execute(request, timeout: .seconds(25))
    guard reply.status == .ok else {
      logger.debug(
        "XRPC mutate non-OK",
        metadata: ["status": .stringConvertible(reply.status.code), "method": .string(method)]
      )
      throw HTTPError(.badGateway, message: "PDS \(method) failed (\(reply.status.code))")
    }
    let frame = try await reply.body.collect(upTo: 1024 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: frame)) as? [String: Any]
    else { return [:] }
    return json
  }

  private func executeJSON(url: String, auth: AuthContext?) async throws -> [String: Any] {
    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")
    if let auth {
      let payload = auth.authorizationForwardingValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !payload.isEmpty {
        request.headers.add(name: "Authorization", value: payload)
      }
      if let dpop = auth.dpopProof?.trimmingCharacters(in: .whitespacesAndNewlines), !dpop.isEmpty {
        request.headers.add(name: "DPoP", value: dpop)
      }
    }

    let reply = try await httpClient.execute(request, timeout: .seconds(25))
    guard reply.status == .ok else {
      if reply.status.code == 404 { return [:] }
      logger.debug("XRPC non-OK", metadata: ["status": .stringConvertible(reply.status.code), "url": .string(url)])
      return [:]
    }

    let frame = try await reply.body.collect(upTo: 1024 * 1024)
    guard
      let json = try? JSONSerialization.jsonObject(with: Data(buffer: frame)) as? [String: Any]
    else {
      return [:]
    }
    return json
  }

  private static func sortRecordsNewestFirst(_ records: [[String: Any]]) -> [[String: Any]] {
    records.sorted { a, b in
      let ta = (a["value"] as? [String: Any]).flatMap { dateString(from: $0) } ?? ""
      let tb = (b["value"] as? [String: Any]).flatMap { dateString(from: $0) } ?? ""
      if ta != tb { return ta > tb }
      let ua = a["uri"] as? String ?? ""
      let ub = b["uri"] as? String ?? ""
      return ua > ub
    }
  }

  private static func dateString(from value: [String: Any]) -> String {
    (value["publishedAt"] as? String)
      ?? (value["createdAt"] as? String)
      ?? (value["indexedAt"] as? String)
      ?? ""
  }
}
