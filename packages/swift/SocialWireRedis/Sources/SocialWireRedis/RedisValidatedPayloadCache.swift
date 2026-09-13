import Foundation
import Logging

/// Only public corpus payloads belong here. Viewer-dependent Circle responses bypass this cache.
/// A hit is usable only after the caller reads the exact current membership and row versions
/// from the authoritative serving views. Redis availability never determines service health.
public actor RedisValidatedPayloadCache {
  private struct Entry<Value: Codable & Sendable>: Codable, Sendable {
    let revision: String
    let value: Value
  }

  private let cache: RedisCacheClient
  private let namespace: RedisKeyNamespace
  private let maximumPayloadBytes: Int
  private var inFlight: [String: Task<Data, Error>] = [:]
  private let domain: String
  private let logger: Logger
  private var counts: [String: Int] = [:]
  private var lastReportAt: Date?


  public init(
    commands: any RedisCommandClient, environment: String, maximumPayloadBytes: Int = 1_048_576,
    logger: Logger = Logger(label: "wire-corpus.cache"),
    domain: String = "wire-public-payload"
  ) {
    cache = RedisCacheClient(commands: commands)
    namespace = RedisKeyNamespace(environment: environment, version: "corpus-payload-v1")
    self.maximumPayloadBytes = maximumPayloadBytes
    self.logger = logger
    self.domain = domain
  }

  public func value<Value: Codable & Sendable>(
    _ type: Value.Type,
    scope: [String],
    revision: String,
    now: Date,
    lifetime: TimeInterval = 60,
    currentRevision: @escaping @Sendable () async throws -> String,
    validatesMembership: @escaping @Sendable (Value) -> Bool = { _ in true },
    load: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let key = namespace.key(domain: domain, identifiers: scope)
    do {
      let lookup = try await cache.lookup(Entry<Value>.self, key: key, now: now)
      if case .fresh(let envelope) = lookup, envelope.value.revision == revision,
        validatesMembership(envelope.value.value)
      {
        record("hit", scope: scope, now: now)
        return envelope.value.value
      }
    } catch {
      record("redis_error", scope: scope, now: now)
    }
    record("miss", scope: scope, now: now)
    // Include the authoritative revision in coalescing: a request after a moderation
    // change must never join an older request whose database snapshot predates it.
    let flightKey = key + ":" + RedisKeyNamespace.digest(revision)
    if let task = inFlight[flightKey] {
      return try JSONDecoder().decode(Value.self, from: await task.value)
    }
    // Bound concurrent miss bookkeeping during a crawl or Redis outage.
    guard inFlight.count < 128 else { return try await load() }
    let task = Task<Data, Error> {
      let value = try await load()
      let data = try JSONEncoder().encode(value)
      // A concurrent source edit or membership change during loading prevents cache fill.
      // Never associate a payload from a later snapshot with an older revision.
      if data.count <= self.maximumPayloadBytes, lifetime > 0, validatesMembership(value),
        (try? await currentRevision()) == revision
      {
        do {
          try await self.cache.store(
            Entry(revision: revision, value: value), key: key,
            policy: RedisCachePolicy(
              freshDuration: lifetime, hardDuration: lifetime, maximumJitterFraction: 0), now: now)
          self.record("fill", scope: scope, now: now)
        } catch {
          self.record("redis_error", scope: scope, now: now)
        }
      }
      return data
    }
    inFlight[flightKey] = task
    defer { inFlight.removeValue(forKey: flightKey) }
    return try JSONDecoder().decode(Value.self, from: await task.value)
  }

  public func statistics() -> [String: Int] { counts }

  private func record(_ outcome: String, scope: [String], now: Date) {
    let allowed = ["feed", "edition", "item", "catalog"]
    let domain = scope.first.flatMap { allowed.contains($0) ? $0 : nil } ?? "other"
    counts[domain + "_" + outcome, default: 0] += 1
    guard let lastReportAt else { self.lastReportAt = now; return }
    guard now.timeIntervalSince(lastReportAt) >= 60 else { return }
    logger.info("Wire public payload cache minute totals", metadata:
      counts.mapValues { .stringConvertible($0) })
    counts.removeAll(keepingCapacity: true)
    self.lastReportAt = now
  }

}
