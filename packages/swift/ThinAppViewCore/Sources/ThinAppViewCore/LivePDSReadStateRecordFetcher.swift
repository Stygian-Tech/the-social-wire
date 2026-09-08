import AsyncHTTPClient
import Foundation
import ReadStateCore

/// A small, redirect-free pool prevents a public PDS response from redirecting
/// verification requests into Railway's private network. No viewer credentials are sent.
final class LivePDSReadStateRecordFetcher: Sendable {
  private let httpClient: HTTPClient
  private let plcURL: String

  init(plcURL: String) {
    self.plcURL = plcURL
    var config = HTTPClient.Configuration()
    config.redirectConfiguration = .disallow
    config.timeout.read = .seconds(15)
    config.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 2
    httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
  }

  deinit {
    let client = httpClient
    Task { try? await client.shutdown() }
  }

  func fetch(viewerDid: String, collection: String, key: String, cid: String?) async throws -> PDSReadStateFetchedRecord {
    guard let base = try await ThinAppViewPdsResolution.resolvePdsBase(
      repoDid: viewerDid, plcBase: plcURL, httpClient: httpClient),
      var url = URLComponents(string: base + "/xrpc/com.atproto.repo.getRecord") else {
      throw ReadStateError.incompleteGeneration
    }
    url.queryItems = [URLQueryItem(name: "repo", value: viewerDid),
      URLQueryItem(name: "collection", value: collection), URLQueryItem(name: "rkey", value: key)]
    if let cid { url.queryItems?.append(URLQueryItem(name: "cid", value: cid)) }
    guard let value = url.string else { throw ReadStateError.invalidReference }
    var request = HTTPClientRequest(url: value)
    request.headers.add(name: "Accept", value: "application/json")
    let response = try await httpClient.execute(request, timeout: .seconds(15))
    guard response.status == .ok else {
      try await HTTPResponseBodyDrain.drainOrCancel(response.body)
      throw ReadStateError.incompleteGeneration
    }
    let body = try await response.body.collect(upTo: ReadStateValidation.maximumRecordBytes + 4096)
    guard let envelope = try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
      let uri = envelope["uri"] as? String, let returnedCID = envelope["cid"] as? String,
      let record = envelope["value"] as? [String: Any] else { throw ReadStateError.invalidRecord }
    return PDSReadStateFetchedRecord(uri: uri, cid: returnedCID,
      json: try JSONSerialization.data(withJSONObject: record))
  }
}
