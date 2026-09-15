import Foundation

/// Fixed-cardinality, request-local diagnostics. Never accepts SQL or request data.
public final class AppViewFeedRequestTimings: @unchecked Sendable {
  public enum Stage: String, CaseIterable, Sendable {
    case cacheLookup = "cache_lookup"
    case refreshLease = "refresh_lease"
    case publicationSelect = "publication_select"
    case cacheStore = "cache_store"
    case readState = "read_state"
  }

  @TaskLocal public static var current: AppViewFeedRequestTimings?
  private let lock = NSLock()
  private var values: [String: Int64] = [:]
  private var finished = false
  private static let maximumCount: Int64 = 10_000
  private static let maximumMilliseconds: Int64 = 3_600_000
  private static let keys = Stage.allCases.map(\.rawValue) + ["pg_pool_wait", "pg_transaction"]

  public init() {}

  public static func start(_ stage: Stage, at: ContinuousClock.Instant = .now) -> Span? {
    current.map { Span(owner: $0, key: stage.rawValue, started: at) }
  }

  public static func measure<Value: Sendable>(
    _ stage: Stage, isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> Value
  ) async rethrows -> Value {
    let span = start(stage)
    defer { span?.finish() }
    return try await operation()
  }

  static func startPoolWait(at: ContinuousClock.Instant = .now) -> Span? {
    current.map { Span(owner: $0, key: "pg_pool_wait", started: at) }
  }

  static func startTransaction(at: ContinuousClock.Instant = .now) -> Span? {
    current.map { Span(owner: $0, key: "pg_transaction", started: at) }
  }

  static func recordQuery() {
    guard let timings = current else { return }
    timings.lock.withLock {
      guard !timings.finished else { return }
      timings.values["pg_query_count"] = min(maximumCount, (timings.values["pg_query_count"] ?? 0) + 1)
    }
  }

  /// Sealing excludes late background completions and makes the one log stable.
  public func finish() -> [String: Int64] {
    lock.withLock {
      finished = true
      var result = ["pg_query_count": values["pg_query_count"] ?? 0]
      for key in Self.keys {
        result[key + "_ms"] = values[key + "_ms"] ?? 0
        result[key + "_count"] = values[key + "_count"] ?? 0
      }
      return result
    }
  }

  private func record(key: String, elapsed: Duration) {
    let parts = elapsed.components
    let milliseconds = Int64(max(0, min(Double(Self.maximumMilliseconds),
      Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000)))
    lock.withLock {
      guard !finished else { return }
      values[key + "_ms"] = min(Self.maximumMilliseconds, (values[key + "_ms"] ?? 0) + milliseconds)
      values[key + "_count"] = min(Self.maximumCount, (values[key + "_count"] ?? 0) + 1)
    }
  }

  public final class Span: @unchecked Sendable {
    private let lock = NSLock()
    private let owner: AppViewFeedRequestTimings
    private let key: String
    private let started: ContinuousClock.Instant
    private var finished = false

    fileprivate init(owner: AppViewFeedRequestTimings, key: String, started: ContinuousClock.Instant) {
      self.owner = owner
      self.key = key
      self.started = started
    }

    public func finish(at: ContinuousClock.Instant = .now) {
      lock.withLock {
        guard !finished else { return }
        finished = true
        owner.record(key: key, elapsed: started.duration(to: at))
      }
    }
  }
}
