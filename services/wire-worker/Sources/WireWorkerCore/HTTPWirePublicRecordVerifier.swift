import AsyncHTTPClient
import Foundation

struct HTTPWirePublicRecordVerifier: WirePublicRecordVerifying {
  private let transport: any WirePublicRecordHTTPTransport
  private let now: @Sendable () -> Date

  init(httpClient: HTTPClient) {
    self.init(transport: LiveWirePublicRecordHTTPTransport(httpClient: httpClient))
  }

  init(transport: any WirePublicRecordHTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
    self.transport = transport
    self.now = now
  }

  func verify(uri: String, expectedCID: String?) async throws -> WirePublicRecordVerification {
    let reference = try WirePublicRecordReference(uri)
    if let expectedCID, !WirePublicRecordReference.validCID(expectedCID) {
      throw WirePublicRecordQueryError.invalidReference
    }
    // Recommendation recovery must bind to the exact retained recommendation.
    if reference.collection == "site.standard.graph.recommend", expectedCID == nil {
      throw WirePublicRecordQueryError.invalidReference
    }
    let did = try await object(at: reference.didDocumentURL(), maximumBytes: 64 * 1_024)
    guard did["id"] as? String == reference.repoDID,
      let services = did["service"] as? [[String: Any]]
    else { throw WirePublicRecordQueryError.invalidResponse }
    let endpoints = services.compactMap { service -> String? in
      guard ["#atproto_pds", reference.repoDID + "#atproto_pds"].contains(service["id"] as? String ?? ""),
        service["type"] as? String == "AtprotoPersonalDataServer"
      else { return nil }
      return service["serviceEndpoint"] as? String
    }
    guard endpoints.count == 1, let base = WirePublicEndpointValidator.validatedBase(endpoints[0]),
      URL(string: base)?.port == nil || URL(string: base)?.port == 443
    else { throw WirePublicRecordQueryError.unsafeEndpoint }
    guard try await active(reference.repoDID, base: base) else {
      return .inactive(WirePublicRecordObservation(uri: uri, expectedCID: expectedCID,
        repositoryRevision: nil, pdsBase: base, observedAt: now()))
    }
    let before = try await repositoryCommit(reference.repoDID, base: base)
    let recordURL = try endpoint(base, method: "com.atproto.repo.getRecord", query: [
      "repo": reference.repoDID, "collection": reference.collection, "rkey": reference.recordKey,
    ])
    let record = try await object(at: recordURL, maximumBytes: 1_024 * 1_024, allowMissing: true)
    let after = try await repositoryCommit(reference.repoDID, base: base)
    guard before == after else { throw WirePublicRecordQueryError.repositoryChanged }
    let stillActive = try await active(reference.repoDID, base: base)
    let observation = WirePublicRecordObservation(uri: uri, expectedCID: expectedCID,
      repositoryRevision: after.revision, pdsBase: base, observedAt: now())
    guard stillActive else { return .inactive(observation) }
    guard !record.isEmpty else { return .missing(observation) }
    guard record["uri"] as? String == reference.uri, let cid = record["cid"] as? String,
      WirePublicRecordReference.validCID(cid), let value = record["value"] as? [String: Any],
      value["$type"] as? String == reference.collection
    else { throw WirePublicRecordQueryError.invalidResponse }
    if let expectedCID, cid != expectedCID { return .changed(currentCID: cid, observation: observation) }
    return .verified(WireVerifiedPublicRecord(
      uri: uri, repoDID: reference.repoDID, collection: reference.collection,
      recordKey: reference.recordKey, cid: cid, repositoryRevision: after.revision, pdsBase: base,
      recordJSON: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), observedAt: now()))
  }

  private func active(_ did: String, base: String) async throws -> Bool {
    let response = try await object(at: endpoint(base, method: "com.atproto.sync.getRepoStatus", query: ["did": did]), maximumBytes: 64 * 1_024)
    guard response["did"] as? String == did, let active = response["active"] as? Bool else {
      throw WirePublicRecordQueryError.invalidResponse
    }
    return active
  }

  private func repositoryCommit(_ did: String, base: String) async throws -> (cid: String, revision: String) {
    let response = try await object(at: endpoint(base, method: "com.atproto.sync.getLatestCommit", query: ["did": did]), maximumBytes: 64 * 1_024)
    guard let revision = response["rev"] as? String,
      revision.utf8.count == 13,
      revision.utf8.allSatisfy({ "234567abcdefghijklmnopqrstuvwxyz".utf8.contains($0) }),
      let cid = response["cid"] as? String, WirePublicRecordReference.validCID(cid)
    else { throw WirePublicRecordQueryError.invalidResponse }
    return (cid: cid, revision: revision)
  }

  private func endpoint(_ base: String, method: String, query: [String: String]) throws -> URL {
    var components = URLComponents(string: base + "/xrpc/" + method)
    components?.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
    guard let url = components?.url else { throw WirePublicRecordQueryError.unsafeEndpoint }
    return url
  }

  private func object(at url: URL, maximumBytes: Int, allowMissing: Bool = false) async throws -> [String: Any] {
    try Task.checkCancellation()
    let response: WirePublicRecordHTTPResponse
    do {
      response = try await transport.get(url, maximumBytes: maximumBytes)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as WirePublicRecordQueryError {
      throw error
    } catch WirePublicationQueryError.unsafeEndpoint {
      throw WirePublicRecordQueryError.unsafeEndpoint
    } catch {
      // Network/DNS errors are retryable, without exposing transport diagnostics
      // or any server-controlled response body to persisted failure metadata.
      throw WirePublicRecordQueryError.unavailable
    }
    try Task.checkCancellation()
    guard response.body.count <= maximumBytes else { throw WirePublicRecordQueryError.responseTooLarge }
    if (300..<400).contains(response.status) { throw WirePublicRecordQueryError.redirected }
    if response.status == 429 || response.status >= 500 {
      throw WirePublicRecordQueryError.transientStatus(response.status)
    }
    guard let value = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
      throw WirePublicRecordQueryError.invalidResponse
    }
    if allowMissing, [400, 404].contains(response.status), value["error"] as? String == "RecordNotFound" {
      return [:]
    }
    guard response.status == 200, !value.isEmpty else { throw WirePublicRecordQueryError.invalidResponse }
    return value
  }
}
