import AsyncHTTPClient
import Foundation
import NIOCore

struct HTTPWireLabelQueryClient: WireLabelQuerying {
  private struct ResponseDocument: Decodable {
    struct Label: Decodable {
      let src: String
      let uri: String
      let val: String
      let neg: Bool?
      let cts: String
      let exp: String?
    }

    let cursor: String?
    let labels: [Label]
  }

  let httpClient: HTTPClient

  func query(
    labeler: WireLabelerEndpoint,
    uriPatterns: [String],
    cursor: String?
  ) async throws -> WireLabelQueryPage {
    guard !uriPatterns.isEmpty, uriPatterns.count <= 25 else {
      throw WireLabelQueryError.invalidURL
    }
    var components = URLComponents(
      url: labeler.baseURL.appendingPathComponent("xrpc/com.atproto.label.queryLabels"),
      resolvingAgainstBaseURL: false
    )
    var queryItems = uriPatterns.map { URLQueryItem(name: "uriPatterns", value: $0) }
    queryItems.append(URLQueryItem(name: "sources", value: labeler.sourceDID))
    queryItems.append(URLQueryItem(name: "limit", value: "250"))
    if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
    components?.queryItems = queryItems
    guard let url = components?.url?.absoluteString else { throw WireLabelQueryError.invalidURL }

    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")
    request.headers.add(name: "User-Agent", value: "TheSocialWire-WireWorker/1")
    let response = try await httpClient.execute(request, timeout: .seconds(5))
    guard response.status == .ok else {
      throw WireLabelQueryError.unexpectedStatus(Int(response.status.code))
    }
    let body = try await response.body.collect(upTo: 2 * 1024 * 1024)
    guard let document = try? JSONDecoder().decode(ResponseDocument.self, from: Data(buffer: body))
    else { throw WireLabelQueryError.invalidResponse }
    return WireLabelQueryPage(
      cursor: document.cursor,
      labels: document.labels.map {
        WireLabelQueryRecord(
          sourceDID: $0.src,
          subjectURI: $0.uri,
          value: $0.val,
          negated: $0.neg ?? false,
          createdAt: $0.cts,
          expiresAt: $0.exp
        )
      }
    )
  }
}
