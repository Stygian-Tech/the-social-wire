import Foundation

/// Short-lived, per-store observations; never used to authorize ingestion or recovery actions.
actor IngestionInboxSnapshotCache {
  typealias Value = [String: IngestionInboxMetrics]

  private let lifetime: Duration
  private var cached: (value: Value, expiresAt: ContinuousClock.Instant)?
  private struct Waiter {
    let continuation: CheckedContinuation<Value, any Error>
    let startedAt: ContinuousClock.Instant
    let load: @Sendable () async throws -> Value
  }
  private struct Flight {
    let id: UUID
    let task: Task<Void, Never>
    let startedAt: ContinuousClock.Instant
    var cancelled = false
    var waiters: [UUID: Waiter]
  }
  private var inFlight: Flight?
  private var pending: [UUID: Waiter] = [:]

  var waiterCount: Int { (inFlight?.waiters.count ?? 0) + pending.count }

  init(lifetime: Duration = .seconds(5)) {
    self.lifetime = lifetime
  }

  func value(
    now: ContinuousClock.Instant = .now,
    load: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    if let cached, now < cached.expiresAt { return cached.value }
    let id = UUID()
    let result = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let waiter = Waiter(continuation: continuation, startedAt: now, load: load)
        if inFlight?.cancelled == true {
          // Do not overlap a replacement with a cancelled loader still retiring its connection.
          pending[id] = waiter
        } else if inFlight != nil {
          inFlight?.waiters[id] = waiter
        } else {
          start(waiters: [id: waiter])
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
    try Task.checkCancellation()
    return result
  }

  private func start(waiters: [UUID: Waiter]) {
    guard let first = waiters.values.min(by: { $0.startedAt < $1.startedAt }) else { return }
    let id = UUID()
    let task = Task {
      let result: Result<Value, any Error>
      do {
        try Task.checkCancellation()
        let value = try await first.load()
        try Task.checkCancellation()
        result = .success(value)
      } catch { result = .failure(error) }
      self.complete(id: id, result: result)
    }
    inFlight = Flight(id: id, task: task, startedAt: first.startedAt, waiters: waiters)
  }

  private func cancelWaiter(_ id: UUID) {
    if let waiter = pending.removeValue(forKey: id) {
      waiter.continuation.resume(throwing: CancellationError())
      return
    }
    guard let waiter = inFlight?.waiters.removeValue(forKey: id) else { return }
    waiter.continuation.resume(throwing: CancellationError())
    if inFlight?.waiters.isEmpty == true {
      inFlight?.cancelled = true
      inFlight?.task.cancel()
    }
  }

  private func complete(id: UUID, result: Result<Value, any Error>) {
    guard let flight = inFlight, flight.id == id else { return }
    inFlight = nil
    if !flight.cancelled, case .success(let value) = result {
      // Start the TTL before collection; query or teardown time never refreshes old evidence.
      cached = (value, flight.startedAt.advanced(by: lifetime))
    }
    for waiter in flight.waiters.values { waiter.continuation.resume(with: result) }
    let next = pending
    pending.removeAll()
    start(waiters: next)
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
