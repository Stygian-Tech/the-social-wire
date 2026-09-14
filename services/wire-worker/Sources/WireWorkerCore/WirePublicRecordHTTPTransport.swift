import Foundation

protocol WirePublicRecordHTTPTransport: Sendable {
  /// Public HTTPS GET only, no credentials or redirects, with bounded bodies.
  func get(_ url: URL, maximumBytes: Int) async throws -> WirePublicRecordHTTPResponse
}
