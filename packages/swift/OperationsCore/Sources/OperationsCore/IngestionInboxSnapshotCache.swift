import Foundation

/// Short-lived, per-store observations; never used to authorize ingestion or recovery actions.
actor IngestionInboxSnapshotCache {
  typealias Value = [String: IngestionInboxMetrics]

  private let lifetime: Duration
  private var cached: (value: Value, expiresAt: ContinuousClock.Instant)?
  private var inFlight: Task<Value, any Error>?

  init(lifetime: Duration = .seconds(5)) {
    self.lifetime = lifetime
  }

  func value(
    now: ContinuousClock.Instant = .now,
    load: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    if let cached, now < cached.expiresAt { return cached.value }
    if let inFlight { return try await inFlight.value }
    let task = Task { try await load() }
    inFlight = task
    defer { inFlight = nil }
    let value = try await task.value
    // Start the TTL before the query, so a slow query cannot acquire a fresh five seconds.
    cached = (value, now.advanced(by: lifetime))
    return value
  }

  nonisolated static func aged(_ value: IngestionInboxMetrics, at: Date) -> IngestionInboxMetrics {
    IngestionInboxMetrics(
      pending: value.pending, leased: value.leased, retrying: value.retrying,
      applied: value.applied, filteredScope: value.filteredScope, deadLetters: value.deadLetters,
      total: value.total, oldestPendingAt: value.oldestPendingAt,
      oldestPendingAgeSeconds: value.oldestPendingAt.map { max(0, at.timeIntervalSince($0)) })
  }

  nonisolated static func total(
    _ values: some Sequence<IngestionInboxMetrics>, at: Date
  ) -> IngestionInboxMetrics {
    // Derive the global values from the same grouped database snapshot, avoiding another scan
    // and preventing a concurrent intake/claim from disagreeing with the source breakdown.
    let total = values.reduce(IngestionInboxMetrics()) { result, value in
      IngestionInboxMetrics(
        pending: result.pending + value.pending, leased: result.leased + value.leased,
        retrying: result.retrying + value.retrying, applied: result.applied + value.applied,
        filteredScope: result.filteredScope + value.filteredScope,
        deadLetters: result.deadLetters + value.deadLetters, total: result.total + value.total,
        oldestPendingAt: [result.oldestPendingAt, value.oldestPendingAt].compactMap { $0 }.min())
    }
    return aged(total, at: at)
  }
}
