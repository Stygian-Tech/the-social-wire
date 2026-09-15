import Foundation

/// Bounded discovery cache. Each flight belongs to the cache; cancellation
/// removes only that request's waiter, preserving the fetch for other callers.
actor JWKSVerificationCache<Value: Sendable & Equatable> {
  typealias CacheError = JWKSVerificationCacheFailure

  private struct Entry: Sendable {
    let value: Value
    let expiresAt: Date
    let cost: Int
  }

  private struct Flight {
    var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
  }

  private let now: @Sendable () -> Date
  private let maximumEntries: Int
  private let loadTimeout: Duration
  private let maximumInFlight: Int
  private let maximumWaitersPerFlight: Int
  private let maximumCost: Int
  private let cost: @Sendable (Value) -> Int
  private var cachedCost = 0
  private var entries: [String: Entry] = [:]
  private var inFlight: [String: Flight] = [:]

  init(
    maximumEntries: Int = 10_000,
    loadTimeout: Duration = .seconds(10),
    maximumInFlight: Int = 64,
    maximumWaitersPerFlight: Int = 256,
    maximumCost: Int = .max,
    cost: @escaping @Sendable (Value) -> Int = { _ in 1 },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.maximumEntries = max(1, maximumEntries)
    self.loadTimeout = max(.milliseconds(1), loadTimeout)
    self.maximumInFlight = max(1, maximumInFlight)
    self.maximumWaitersPerFlight = max(1, maximumWaitersPerFlight)
    self.maximumCost = max(1, maximumCost)
    self.cost = cost
    self.now = now
  }

  func value(
    forKey key: String,
    refreshing previous: Value? = nil,
    ttl: @escaping @Sendable (Value) -> TimeInterval,
    load: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    if let entry = entries[key], entry.expiresAt > now(), entry.value != previous {
      return entry.value
    }
    let waiterID = UUID()
    let value: Value = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        if var flight = inFlight[key] {
          guard flight.waiters.count < maximumWaitersPerFlight else {
            continuation.resume(throwing: CacheError.overloaded)
            return
          }
          flight.waiters[waiterID] = continuation
          inFlight[key] = flight
          return
        }
        guard inFlight.count < maximumInFlight else {
          continuation.resume(throwing: CacheError.overloaded)
          return
        }
        inFlight[key] = Flight(waiters: [waiterID: continuation])
        let deadline = ContinuousClock.now.advanced(by: loadTimeout)
        // Deliberately unstructured: one HTTP fetch serves independently
        // cancellable requests and remains covered by the in-flight limit.
        Task {
          let result: Result<Value, any Error>
          do { result = .success(try await Self.loadBeforeDeadline(deadline, load: load)) }
          catch { result = .failure(error) }
          finish(key: key, result: result, ttl: ttl)
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(key: key, id: waiterID) }
    }
    try Task.checkCancellation()
    return value
  }

  /// The deadline owns both response headers and body consumption. Keep the
  /// flight occupied until cancellation finishes so timed-out work cannot become
  /// an untracked fetch when the cache admits a replacement.
  private nonisolated static func loadBeforeDeadline(
    _ deadline: ContinuousClock.Instant,
    load: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      defer { group.cancelAll() }
      group.addTask { try await load() }
      group.addTask {
        try await ContinuousClock().sleep(until: deadline)
        throw CacheError.timedOut
      }
      guard let value = try await group.next() else { throw CancellationError() }
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw CacheError.timedOut }
      return value
    }
  }

  func cachedValue(forKey key: String) -> Value? {
    guard let entry = entries[key], entry.expiresAt > now() else { return nil }
    return entry.value
  }

  private func cancelWaiter(key: String, id: UUID) {
    guard let continuation = inFlight[key]?.waiters.removeValue(forKey: id) else { return }
    continuation.resume(throwing: CancellationError())
  }

  private func finish(
    key: String, result: Result<Value, any Error>, ttl: @Sendable (Value) -> TimeInterval
  ) {
    guard let flight = inFlight.removeValue(forKey: key) else { return }
    if case .success(let value) = result {
      let instant = now()
      for expiredKey in entries.compactMap({ $0.value.expiresAt <= instant ? $0.key : nil }) {
        removeEntry(forKey: expiredKey)
      }
      let lifetime = ttl(value)
      removeEntry(forKey: key)
      let (entryCost, overflow) = key.utf8.count.addingReportingOverflow(max(0, cost(value)))
      if lifetime > 0, !overflow, entryCost <= maximumCost {
        while entries.count >= maximumEntries || cachedCost > maximumCost - entryCost {
          guard let oldest = entries.min(by: {
            $0.value.expiresAt == $1.value.expiresAt
              ? $0.key < $1.key : $0.value.expiresAt < $1.value.expiresAt
          })?.key else { break }
          removeEntry(forKey: oldest)
        }
        entries[key] = Entry(
          value: value, expiresAt: instant.addingTimeInterval(lifetime), cost: entryCost)
        cachedCost += entryCost
      }
    }
    for continuation in flight.waiters.values { continuation.resume(with: result) }
  }

  private func removeEntry(forKey key: String) {
    if let entry = entries.removeValue(forKey: key) { cachedCost -= entry.cost }
  }
}
