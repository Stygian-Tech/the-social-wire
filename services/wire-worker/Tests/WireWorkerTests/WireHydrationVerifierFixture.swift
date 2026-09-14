import Foundation

@testable import WireWorkerCore

/// Controlled public observations without network traffic; records concurrency and identity checks.
actor WireHydrationVerifierFixture: WirePublicRecordVerifying {
  private var observations: [String: WirePublicRecordVerification] = [:]
  private var failures: [String: WirePublicRecordQueryError] = [:]
  private var requests: [(uri: String, expectedCID: String?)] = []
  private var activeRequests = 0
  private var maximumActiveRequests = 0
  private let delayNanoseconds: UInt64
  private var beforeResponse: (@Sendable (String) async throws -> Void)?

  init(
    delayNanoseconds: UInt64 = 0,
    beforeResponse: (@Sendable (String) async throws -> Void)? = nil
  ) {
    self.delayNanoseconds = delayNanoseconds
    self.beforeResponse = beforeResponse
  }

  func set(_ observation: WirePublicRecordVerification, for uri: String) {
    observations[uri] = observation
    failures.removeValue(forKey: uri)
  }

  func fail(_ error: WirePublicRecordQueryError, for uri: String) {
    failures[uri] = error
  }

  func setBeforeResponse(_ action: @escaping @Sendable (String) async throws -> Void) {
    beforeResponse = action
  }

  func calls() -> [(uri: String, expectedCID: String?)] { requests }
  func maximumConcurrency() -> Int { maximumActiveRequests }

  func verify(uri: String, expectedCID: String?) async throws -> WirePublicRecordVerification {
    requests.append((uri, expectedCID))
    activeRequests += 1
    maximumActiveRequests = max(maximumActiveRequests, activeRequests)
    defer { activeRequests -= 1 }
    if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
    try await beforeResponse?(uri)
    try Task.checkCancellation()
    if let error = failures[uri] { throw error }
    guard let observation = observations[uri] else { throw WirePublicRecordQueryError.unavailable }
    return observation
  }
}
