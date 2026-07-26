import AsyncHTTPClient
import NIOCore

protocol PDSHTTPTransport: Sendable {
  func execute(
    _ request: HTTPClientRequest,
    timeout: TimeAmount
  ) async throws -> HTTPClientResponse
}

struct LivePDSHTTPTransport: PDSHTTPTransport, Sendable {
  let httpClient: HTTPClient

  func execute(
    _ request: HTTPClientRequest,
    timeout: TimeAmount
  ) async throws -> HTTPClientResponse {
    try await httpClient.execute(request, timeout: timeout)
  }
}

struct RateLimitedPDSHTTPTransport: PDSHTTPTransport, Sendable {
  let upstream: any PDSHTTPTransport
  let limiter: PDSRequestRateLimiter

  func execute(
    _ request: HTTPClientRequest,
    timeout: TimeAmount
  ) async throws -> HTTPClientResponse {
    try await limiter.waitForPermit()
    try Task.checkCancellation()
    return try await upstream.execute(request, timeout: timeout)
  }
}
