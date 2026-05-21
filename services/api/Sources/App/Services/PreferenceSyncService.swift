import AsyncHTTPClient
import GatewayCore
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

/// Short-TTL wrappers around `com.atproto.repo.getRecord` for lexical preferences plus generic keyed records.
actor PreferenceSyncService {
  private let httpClient: HTTPClient
  private let cache: any CacheStore
  private let plcURL: String
  private let logger: Logger

  private static let preferencesCollection = "com.thesocialwire.preferences"
  private static let preferencesRKey = "self"

  init(httpClient: HTTPClient, cache: any CacheStore, plcURL: String, logger: Logger) {
    self.httpClient = httpClient
    self.cache = cache
    self.plcURL = plcURL
    self.logger = logger
  }

  func preferencesResponse(auth: AuthContext, ifNoneMatch: String?) async throws -> Response {
    try await lexicalPreferencesEnvelope(auth: auth, ifNoneMatch: ifNoneMatch)
  }

  func genericCachedRecordGET(
    auth: AuthContext,
    collection: String,
    rkey: String,
    ifNoneMatch: String?
  ) async throws -> Response {
    guard !collection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw HTTPError(.badRequest, message: "`collection` must be provided")
    }
    guard !rkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw HTTPError(.badRequest, message: "`rkey` must be provided")
    }

    let scope = "\(collection):\(rkey)"

    if let earlyExit = evaluate304(ifNoneMatch: ifNoneMatch, cid: try await currentCID(for: auth.did, scope: scope))
    {
      return earlyExit
    }

    if let warm = try await cache.cachedPdsRepoRecord(ownerDid: auth.did, scopeKey: scope),
       Date().timeIntervalSince(warm.cachedAt) < CacheStorePdsTTLs.genericRecordTTL
    {
      return serializeRawBlob(snapshot: warm, ifNoneMatch: ifNoneMatch)
    }

    guard
      let pds = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: auth.did,
        plcBase: plcURL,
        httpClient: httpClient
      )
    else {
      throw HTTPError(.badGateway, message: "Could not derive PDS for \(auth.did)")
    }

    let live = try await fetchRecord(repo: auth.did, pdsHost: pds, collection: collection, rkey: rkey, auth: auth)

    try await cache.storePdsRepoRecordPayload(
      ownerDid: auth.did,
      scopeKey: scope,
      cid: live.cid,
      jsonBody: live.jsonBlob,
      cachedAt: Date(),
      expiresAt: Date().addingTimeInterval(CacheStorePdsTTLs.genericWriteHorizon)
    )

    let snapshot = PdsCachedRepoRecordPayload(cid: live.cid, jsonBody: live.jsonBlob, cachedAt: Date())
    return serializeRawBlob(snapshot: snapshot, ifNoneMatch: ifNoneMatch)
  }

  // MARK: - Private

  private func lexicalPreferencesEnvelope(auth: AuthContext, ifNoneMatch: String?) async throws -> Response {
    let scope = "\(Self.preferencesCollection):\(Self.preferencesRKey)"

    if let early304 = evaluate304(ifNoneMatch: ifNoneMatch, cid: try await currentCID(for: auth.did, scope: scope))
    {
      return early304
    }

    if let warm = try await cache.cachedPdsRepoRecord(ownerDid: auth.did, scopeKey: scope),
       Date().timeIntervalSince(warm.cachedAt) < CacheStorePdsTTLs.preferencesCachedPayloadTTL
    {
      return try finalizePreferences(snapshot: warm, ifNoneMatch: ifNoneMatch)
    }

    guard
      let pds = try await ATProtoPdsResolution.resolvePdsBase(
        repoDid: auth.did,
        plcBase: plcURL,
        httpClient: httpClient
      )
    else {
      throw HTTPError(.badGateway, message: "Could not derive PDS for \(auth.did)")
    }

    let livePayload = try await fetchRecord(
      repo: auth.did,
      pdsHost: pds,
      collection: Self.preferencesCollection,
      rkey: Self.preferencesRKey,
      auth: auth
    )

    try await cache.storePdsRepoRecordPayload(
      ownerDid: auth.did,
      scopeKey: scope,
      cid: livePayload.cid,
      jsonBody: livePayload.jsonBlob,
      cachedAt: Date(),
      expiresAt: Date().addingTimeInterval(CacheStorePdsTTLs.preferencesWriteHorizon)
    )

    logger.debug(
      "Preferences cache rewarmed",
      metadata: ["did": .string(auth.did)]
    )

    let snapshot = PdsCachedRepoRecordPayload(
      cid: livePayload.cid,
      jsonBody: livePayload.jsonBlob,
      cachedAt: Date()
    )
    return try finalizePreferences(snapshot: snapshot, ifNoneMatch: ifNoneMatch)
  }

  private struct LiveSnapshot {
    let cid: String?
    let jsonBlob: String
  }

  private func currentCID(for did: String, scope: String) async throws -> String? {
    guard let raw = try await cache.cachedPdsRepoRecord(ownerDid: did, scopeKey: scope)?.cid else {
      return nil
    }
    return trimmedNonempty(raw)
  }

  private func trimmedNonempty(_ cid: String) -> String? {
    let v = cid.trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? nil : v
  }

  private func evaluate304(ifNoneMatch: String?, cid: String?) -> Response? {
    guard
      let serverSide = cid?.trimmingCharacters(in: .whitespacesAndNewlines),
      !serverSide.isEmpty
    else {
      return nil
    }

    guard
      let clientSignal = ifNoneMatch?.trimmingCharacters(in: .whitespacesAndNewlines),
      !clientSignal.isEmpty
    else {
      return nil
    }

    let cleanedClient = clientSignal.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    guard cleanedClient == serverSide else { return nil }

    return Response(status: .notModified)
  }

  private func fetchRecord(
    repo: String,
    pdsHost: String,
    collection: String,
    rkey: String,
    auth: AuthContext
  ) async throws -> LiveSnapshot {
    let base = stripTrailingSlashes(ATProtoPdsResolution.normalizePdsBase(pdsHost))

    guard var comps = URLComponents(string: "\(base)/xrpc/com.atproto.repo.getRecord") else {
      throw HTTPError(.badRequest, message: "Bad PDS endpoint")
    }
    comps.queryItems = [
      URLQueryItem(name: "repo", value: repo),
      URLQueryItem(name: "collection", value: collection),
      URLQueryItem(name: "rkey", value: rkey),
    ]

    guard let urlStr = comps.url?.absoluteString else {
      throw HTTPError(.badRequest, message: "Malformed `getRecord` URL assembly")
    }

    var outbound = HTTPClientRequest(url: urlStr)
    outbound.headers.add(name: "Accept", value: "application/json")

    let authPayload = auth.authorizationForwardingValue.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !authPayload.isEmpty else {
      throw HTTPError(.unauthorized, message: "`Authorization` header echoed upstream unexpectedly empty.")
    }

    outbound.headers.add(name: "Authorization", value: authPayload)

    if let dpopJWT = auth.dpopProof?.trimmingCharacters(in: .whitespacesAndNewlines), !dpopJWT.isEmpty {
      outbound.headers.add(name: "DPoP", value: dpopJWT)
    }

    let reply = try await httpClient.execute(outbound, timeout: .seconds(25))

    guard reply.status == .ok else {
      if reply.status.code == 404 {
        throw HTTPError(.notFound, message: "Record unavailable")
      }
      throw HTTPError(.badGateway, message: "`getRecord` handshake failed \(reply.status.code)")
    }

    let frame = try await reply.body.collect(upTo: 1024 * 1024)
    let textual = String(buffer: frame)
    guard !textual.isEmpty else {
      throw HTTPError(.badGateway, message: "`getRecord` frame decode fault")
    }

    guard let data = textual.data(using: .utf8) else {
      throw HTTPError(.badGateway, message: "`getRecord` UTF-8 coercion fault")
    }

    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw HTTPError(.badGateway, message: "`getRecord` JSON parse fault")
    }

    guard obj["error"] == nil, obj["value"] != nil else {
      throw HTTPError(.badGateway, message: "`getRecord` shape fault")
    }

    let lexicalCIDCaptured = obj["cid"] as? String

    return LiveSnapshot(cid: lexicalCIDCaptured, jsonBlob: textual)
  }

  private func finalizePreferences(snapshot: PdsCachedRepoRecordPayload, ifNoneMatch: String?) throws -> Response {
    if evaluate304(ifNoneMatch: ifNoneMatch, cid: snapshot.cid) != nil {
      return Response(status: .notModified)
    }

    guard let data = snapshot.jsonBody.data(using: .utf8) else {
      throw HTTPError(.badGateway, message: "Cached preference blob invalid UTF-8")
    }

    guard
      let recordRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let lexicalValueSubtree = recordRoot["value"]
    else {
      throw HTTPError(.badGateway, message: "`preferences` lexical blob corrupted")
    }

    let lexicalRevision = snapshot.cid?.trimmingCharacters(in: .whitespacesAndNewlines)

    let bundle: [String: Any] = [
      "etag": lexicalRevision as Any,
      "cid": lexicalRevision as Any,
      "revision": lexicalRevision as Any,
      "cachedAt": ISO8601DateFormatter().string(from: snapshot.cachedAt),
      "record": lexicalValueSubtree,
    ]

    guard JSONSerialization.isValidJSONObject(bundle) else {
      throw HTTPError(.badGateway, message: "`preferences` response bundle serialization fault")
    }

    let outgoing = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])

    var fields: HTTPFields = [.contentType: "application/json; charset=utf-8"]

    if let revisionGlass = lexicalRevision,
       let etagKey = HTTPField.Name("ETag"),
       !revisionGlass.isEmpty
    {
      fields[etagKey] = "\"\(revisionGlass)\""
    }

    return Response(
      status: .ok,
      headers: fields,
      body: .init(byteBuffer: ByteBuffer(bytes: outgoing))
    )
  }

  private func serializeRawBlob(snapshot: PdsCachedRepoRecordPayload, ifNoneMatch: String?) -> Response {
    if evaluate304(ifNoneMatch: ifNoneMatch, cid: snapshot.cid) != nil {
      return Response(status: .notModified)
    }

    var fields: HTTPFields = [.contentType: "application/json; charset=utf-8"]

    if let revisionGlass = snapshot.cid?.trimmingCharacters(in: .whitespacesAndNewlines),
       let etagKey = HTTPField.Name("ETag"),
       !revisionGlass.isEmpty
    {
      fields[etagKey] = "\"\(revisionGlass)\""
    }

    var buffer = ByteBuffer()
    buffer.writeString(snapshot.jsonBody)
    return Response(status: .ok, headers: fields, body: .init(byteBuffer: buffer))
  }

  private func stripTrailingSlashes(_ input: String) -> String {
    var copy = input
    while copy.hasSuffix("/"), copy.count > "https:/".count {
      copy.removeLast()
    }
    return copy
  }
}
