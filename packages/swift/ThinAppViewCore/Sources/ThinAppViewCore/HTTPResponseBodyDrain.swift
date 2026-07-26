import AsyncHTTPClient
import NIOCore

enum HTTPResponseBodyDrain {
  static let maximumDiscardBytes = 64 * 1_024

  /// Consume a small response body so its connection can be reused. If the body exceeds the bound
  /// or cannot be read, stop iterating and release it so AsyncHTTPClient cancels the remaining
  /// stream. Task cancellation is never swallowed.
  static func drainOrCancel(
    _ body: HTTPClientResponse.Body,
    upTo maximumBytes: Int = maximumDiscardBytes
  ) async throws {
    do {
      _ = try await body.collect(upTo: max(0, maximumBytes))
    } catch {
      try Task.checkCancellation()
    }
  }
}
