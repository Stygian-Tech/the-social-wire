import AsyncHTTPClient
import NIOCore

protocol WirePublicationHTTPTransport: Sendable {
  func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> HTTPClientResponse
}

struct LiveWirePublicationHTTPTransport: WirePublicationHTTPTransport {
  let httpClient: HTTPClient

  func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> HTTPClientResponse
  {
    try await httpClient.execute(request, timeout: timeout)
  }
}
