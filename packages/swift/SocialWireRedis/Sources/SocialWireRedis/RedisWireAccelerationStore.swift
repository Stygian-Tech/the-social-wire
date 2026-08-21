import Foundation

/// Disposable acceleration for The Wire. Callers must treat every miss, stale value,
/// malformed response, or command failure as a signal to read authoritative PostgreSQL.
public actor RedisWireAccelerationStore {
  private let cache: RedisCacheClient
  private let rankings: RedisRankingStore
  private let leases: RedisLeaseCoordinator
  private let namespace: RedisKeyNamespace

  public init(
    commands: any RedisCommandClient,
    namespace: RedisKeyNamespace,
    telemetry: RedisTelemetrySink? = nil
  ) {
    self.cache = RedisCacheClient(commands: commands, telemetry: telemetry)
    self.rankings = RedisRankingStore(commands: commands, namespace: namespace)
    self.leases = RedisLeaseCoordinator(commands: commands, namespace: namespace, telemetry: telemetry)
    self.namespace = namespace
  }

  public func upsertCandidates(
    _ candidates: [RedisRankingCandidate],
    window: RedisRankingWindow
  ) async throws {
    try await rankings.upsert(candidates, scope: .global(feed: "wire"), window: window)
  }

  public func topCandidates(
    limit: Int,
    window: RedisRankingWindow
  ) async throws -> [RedisRankingCandidate] {
    try await rankings.top(limit: limit, scope: .global(feed: "wire"), window: window)
  }

  public func storePostMapping(postURI: String, canonicalKey: String, now: Date = Date()) async throws {
    try await cache.store(
      canonicalKey,
      key: namespace.key(domain: "wire-post", identifiers: [postURI]),
      policy: RedisCachePolicy(freshDuration: 3_600, hardDuration: 86_400),
      now: now
    )
  }

  public func postMapping(postURI: String, now: Date = Date()) async throws -> String? {
    switch try await cache.lookup(
      String.self,
      key: namespace.key(domain: "wire-post", identifiers: [postURI]),
      cacheType: "wire_post",
      now: now
    ) {
    case .fresh(let envelope), .stale(let envelope): envelope.value
    case .miss: nil
    }
  }

  public func storeGenerationPage<Value: Codable & Sendable>(
    _ page: Value,
    generationID: String,
    language: String,
    ordinal: Int,
    now: Date = Date()
  ) async throws {
    try await cache.store(
      page,
      key: generationPageKey(generationID: generationID, language: language, ordinal: ordinal),
      policy: RedisCachePolicy(freshDuration: 60, hardDuration: 300, maximumJitterFraction: 0),
      now: now
    )
  }

  public func generationPage<Value: Codable & Sendable>(
    _ type: Value.Type,
    generationID: String,
    language: String,
    ordinal: Int,
    now: Date = Date()
  ) async throws -> Value? {
    switch try await cache.lookup(
      type,
      key: generationPageKey(generationID: generationID, language: language, ordinal: ordinal),
      cacheType: "wire_generation_page",
      now: now
    ) {
    case .fresh(let envelope), .stale(let envelope): envelope.value
    case .miss: nil
    }
  }

  public func storeFeedCatalog<Value: Codable & Sendable>(
    _ catalog: Value,
    now: Date = Date()
  ) async throws {
    try await cache.store(
      catalog,
      key: namespace.key(domain: "wire-catalog", safeComponents: ["current"]),
      policy: RedisCachePolicy(freshDuration: 60, hardDuration: 300, maximumJitterFraction: 0),
      now: now
    )
  }

  public func feedCatalog<Value: Codable & Sendable>(
    _ type: Value.Type,
    now: Date = Date()
  ) async throws -> Value? {
    switch try await cache.lookup(
      type,
      key: namespace.key(domain: "wire-catalog", safeComponents: ["current"]),
      cacheType: "wire_catalog",
      now: now
    ) {
    case .fresh(let envelope), .stale(let envelope): envelope.value
    case .miss: nil
    }
  }

  public func acquireRankingLease(ttl: TimeInterval = 60) async throws -> RedisLease? {
    try await leases.acquire(domain: "wire-rank", resource: "global", ttl: ttl)
  }

  public func releaseRankingLease(_ lease: RedisLease) async throws -> Bool {
    try await leases.release(lease)
  }

  private func generationPageKey(generationID: String, language: String, ordinal: Int) -> String {
    namespace.key(
      domain: "wire-page",
      safeComponents: [language, String(max(0, ordinal))],
      identifiers: [generationID]
    )
  }
}
