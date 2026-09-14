import AsyncHTTPClient
import Foundation

/// One independent, non-overlapping collector shared by readiness, freshness, and heartbeats.
/// Serving requests only read the snapshot; they never contact the ingestion workers.
actor GatewayIngestionHealth {
  private let baseURL: String?
  private let check: @Sendable (String) async throws -> UInt
  private let now: @Sendable () -> Date
  private let lifetime: TimeInterval
  private var latest: GatewayIngestionHealthSnapshot = .unknown
  private var collecting = false

  init(baseURL: String?, httpClient: HTTPClient) {
    self.baseURL = baseURL
    self.check = { try await GatewayDependencyHTTPProbe.status(baseURL: $0, httpClient: httpClient) }
    self.now = Date.init
    self.lifetime = 45
  }

  init(baseURL: String?, lifetime: TimeInterval = 45,
       now: @escaping @Sendable () -> Date = Date.init,
       check: @escaping @Sendable (String) async throws -> UInt) {
    self.baseURL = baseURL
    self.check = check
    self.now = now
    self.lifetime = lifetime
  }

  func snapshot() -> GatewayIngestionHealthSnapshot { latest.evaluated(at: now()) }

  func collectOnce() async throws {
    try Task.checkCancellation()
    guard !collecting else { return }
    collecting = true
    defer { collecting = false }
    let normalized = baseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let normalized, !normalized.isEmpty else {
      latest = .init(poolReadiness: "not_configured", completeness: .unknown,
                     checkedAt: nil, validUntil: nil)
      return
    }
    let state: String
    let degraded: Bool
    do {
      let status = try await check(normalized)
      try Task.checkCancellation()
      state = (200..<300).contains(status) ? "ready" : "failed_http_\(status)"
      degraded = !(200..<300).contains(status)
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      state = "unavailable"
      degraded = true
    }
    let observedAt = now()
    latest = .init(poolReadiness: state, completeness: degraded ? .degraded : .unknown,
                   checkedAt: observedAt, validUntil: observedAt.addingTimeInterval(lifetime))
  }

  func runForever() async throws {
    while !Task.isCancelled {
      try await collectOnce()
      // Schedule from completion: no overlap or catch-up bursts after a slow sample.
      try await Task.sleep(for: .seconds(15))
    }
  }
}
