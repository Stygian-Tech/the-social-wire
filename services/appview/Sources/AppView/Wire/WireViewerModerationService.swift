import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging

actor WireViewerModerationService {
  private let httpClient: HTTPClient
  private let plcURL: String
  private let cache: WireViewerModerationCache
  private let logger: Logger

  init(
    httpClient: HTTPClient,
    plcURL: String,
    cache: WireViewerModerationCache,
    logger: Logger
  ) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.cache = cache
    self.logger = logger
  }

  func requireSnapshot(
    request: Request,
    auth: AuthContext?,
    now: Date
  ) async throws {
    guard let auth, auth.did != GatewayInternalTrustAuthMiddleware.anonymousDiscoveryDID else {
      return
    }
    if await cache.fresh(viewerDID: auth.did, now: now) != nil { return }
    do {
      guard let proofs = WireModerationDPoP.extract(from: request) else {
        throw WireServingError.moderationUnavailable
      }
      let snapshot = try await fetchWithinDeadline(auth: auth, proofs: proofs, now: now)
      await cache.store(snapshot, viewerDID: auth.did)
    } catch {
      if await cache.usable(viewerDID: auth.did, now: now) != nil {
        logger.warning("Serving The Wire with a stale viewer moderation snapshot")
        return
      }
      throw WireServingError.moderationUnavailable
    }
  }

  private func fetchWithinDeadline(
    auth: AuthContext,
    proofs: [String],
    now: Date
  ) async throws -> WireViewerModerationSnapshot {
    try await withThrowingTaskGroup(of: WireViewerModerationSnapshot.self) { group in
      group.addTask { [self] in
        try await fetch(auth: auth, proofs: proofs, now: now)
      }
      group.addTask {
        try await Task.sleep(
          for: .seconds(WireModerationDPoP.appViewColdPathTimeoutSeconds)
        )
        throw WireServingError.moderationUnavailable
      }
      guard let snapshot = try await group.next() else {
        throw WireServingError.moderationUnavailable
      }
      group.cancelAll()
      return snapshot
    }
  }

  private func fetch(
    auth: AuthContext,
    proofs: [String],
    now: Date
  ) async throws -> WireViewerModerationSnapshot {
    guard let pdsBase = try await ATProtoPdsResolution.resolvePdsBase(
      repoDid: auth.did,
      plcBase: plcURL,
      httpClient: httpClient,
      timeout: .seconds(5)
    ) else {
      throw WireServingError.moderationUnavailable
    }

    guard proofs.count == WireModerationDPoP.methods.count else {
      throw WireServingError.moderationUnavailable
    }
    async let preferenceWords = collectMutedWords(
      base: pdsBase, method: WireModerationDPoP.methods[0], auth: auth, proof: proofs[0], query: []
    )
    async let blockedProfiles = collectProfiles(
      base: pdsBase, method: WireModerationDPoP.methods[1], key: "blocks", auth: auth,
      proof: proofs[1]
    )
    async let mutedProfiles = collectProfiles(
      base: pdsBase, method: WireModerationDPoP.methods[2], key: "mutes", auth: auth,
      proof: proofs[2]
    )
    async let mutedListURIs = collectListURIs(
      base: pdsBase, method: WireModerationDPoP.methods[3], auth: auth, proof: proofs[3]
    )
    async let blockedListURIs = collectListURIs(
      base: pdsBase, method: WireModerationDPoP.methods[4], auth: auth, proof: proofs[4]
    )
    let (mutedWords, initialBlocked, muted, mutedLists, blockedLists) = try await (
      preferenceWords, blockedProfiles, mutedProfiles, mutedListURIs, blockedListURIs
    )
    var blocked = initialBlocked
    let listURIs = mutedLists.union(blockedLists)

    for listURI in listURIs.prefix(200) {
      try await collectPublicListMembers(uri: listURI, into: &blocked)
    }

    return WireViewerModerationSnapshot(
      blockedDIDs: blocked,
      mutedDIDs: muted,
      mutedWords: mutedWords.map { $0.lowercased() },
      fetchedAt: now
    )
  }

  private func collectProfiles(
    base: String,
    method: String,
    key: String,
    auth: AuthContext,
    proof: String
  ) async throws -> Set<String> {
    let document = try await fetchDocument(
      base: base, method: method, auth: auth, proof: proof,
      query: [URLQueryItem(name: "limit", value: "100")]
    )
    guard document["cursor"] == nil else { throw WireServingError.moderationUnavailable }
    var result = Set<String>()
    for profile in document[key] as? [[String: Any]] ?? [] {
      if let did = profile["did"] as? String { result.insert(did) }
    }
    return result
  }

  private func collectMutedWords(
    base: String,
    method: String,
    auth: AuthContext,
    proof: String,
    query: [URLQueryItem]
  ) async throws -> [String] {
    Self.mutedWords(
      try await fetchDocument(
        base: base, method: method, auth: auth, proof: proof, query: query
      )
    )
  }

  private func collectListURIs(
    base: String,
    method: String,
    auth: AuthContext,
    proof: String
  ) async throws -> Set<String> {
    let document = try await fetchDocument(
      base: base, method: method, auth: auth, proof: proof,
      query: [URLQueryItem(name: "limit", value: "100")]
    )
    guard document["cursor"] == nil else { throw WireServingError.moderationUnavailable }
    var result = Set<String>()
    for list in document["lists"] as? [[String: Any]] ?? [] {
      if let uri = list["uri"] as? String { result.insert(uri) }
    }
    return result
  }

  private func collectPublicListMembers(uri: String, into result: inout Set<String>) async throws {
    var cursor: String?
    for _ in 0..<20 {
      var query = [
        URLQueryItem(name: "list", value: uri),
        URLQueryItem(name: "limit", value: "100"),
      ]
      if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
      let document = try await fetchPublicDocument(method: "app.bsky.graph.getList", query: query)
      for item in document["items"] as? [[String: Any]] ?? [] {
        if let subject = item["subject"] as? [String: Any], let did = subject["did"] as? String {
          result.insert(did)
        }
      }
      cursor = document["cursor"] as? String
      if cursor == nil { return }
    }
    throw WireServingError.moderationUnavailable
  }

  private func fetchDocument(
    base: String,
    method: String,
    auth: AuthContext,
    proof: String,
    query: [URLQueryItem]
  ) async throws -> [String: Any] {
    try await fetchJSON(
      base: base,
      method: method,
      query: query,
      authorization: auth.authorizationForwardingValue,
      proof: proof
    )
  }

  private func fetchPublicDocument(
    method: String,
    query: [URLQueryItem]
  ) async throws -> [String: Any] {
    try await fetchJSON(
      base: ATProtoPdsResolution.bskyAppViewPublic,
      method: method,
      query: query,
      authorization: nil,
      proof: nil
    )
  }

  private func fetchJSON(
    base: String,
    method: String,
    query: [URLQueryItem],
    authorization: String?,
    proof: String?
  ) async throws -> [String: Any] {
    var components = URLComponents(
      string: "\(ATProtoPdsResolution.normalizePdsBase(base))/xrpc/\(method)"
    )
    components?.queryItems = query.isEmpty ? nil : query
    guard let url = components?.url?.absoluteString else {
      throw WireServingError.moderationUnavailable
    }
    var outbound = HTTPClientRequest(url: url)
    outbound.headers.add(name: "Accept", value: "application/json")
    if let authorization { outbound.headers.add(name: "Authorization", value: authorization) }
    if let proof { outbound.headers.add(name: "DPoP", value: proof) }
    let response = try await httpClient.execute(outbound, timeout: .seconds(5))
    guard response.status == .ok else { throw WireServingError.moderationUnavailable }
    let body = try await response.body.collect(upTo: 2 * 1024 * 1024)
    guard let document = try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any]
    else { throw WireServingError.moderationUnavailable }
    return document
  }

  private static func mutedWords(_ document: [String: Any]) -> [String] {
    guard let preferences = document["preferences"] as? [[String: Any]] else { return [] }
    return preferences.flatMap { preference -> [String] in
      guard (preference["$type"] as? String)?.contains("mutedWordsPref") == true,
        let items = preference["items"] as? [[String: Any]]
      else { return [] }
      return items.compactMap { item in
        guard item["expiresAt"] == nil else { return nil }
        return (item["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
    }
  }
}
