import AsyncHTTPClient
import Foundation

struct SembleProjectionTransportResponse: Sendable {
  let statusCode: Int
  let body: Data
}

protocol SembleProjectionTransport: Sendable {
  func get(path: String, query: [URLQueryItem]) async throws -> SembleProjectionTransportResponse
}

struct HTTPSembleProjectionTransport: SembleProjectionTransport {
  let baseURL: String
  let httpClient: HTTPClient

  func get(path: String, query: [URLQueryItem]) async throws -> SembleProjectionTransportResponse {
    guard var components = URLComponents(string: baseURL + path) else {
      throw SembleProjectionError.upstream("Semble public projection URL is invalid.")
    }
    components.queryItems = query
    guard let url = components.url?.absoluteString else {
      throw SembleProjectionError.upstream("Semble public projection URL is invalid.")
    }
    var request = HTTPClientRequest(url: url)
    request.method = .GET
    request.headers.add(name: "Accept", value: "application/json")
    let response = try await httpClient.execute(request, timeout: .seconds(12))
    let body = try await response.body.collect(upTo: 8 * 1_024 * 1_024)
    return SembleProjectionTransportResponse(
      statusCode: Int(response.status.code),
      body: Data(buffer: body)
    )
  }
}
