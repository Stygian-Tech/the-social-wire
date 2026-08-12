import Foundation

public actor RedisPDSResolutionCache: PDSResolutionCache {
  private enum StoredResolution: Codable, Sendable {
    case resolved(String)
    case unresolved
  }

  private let cache: RedisCacheClient
  private let leases: RedisLeaseCoordinator
  private let namespace: RedisKeyNamespace

  public init(
    commands: any RedisCommandClient,
    environment: String,
    telemetry: RedisTelemetrySink? = nil
  ) {
    let namespace = RedisKeyNamespace(environment: environment)
    self.cache = RedisCacheClient(commands: commands, telemetry: telemetry)
    self.leases = RedisLeaseCoordinator(commands: commands, namespace: namespace, telemetry: telemetry)
    self.namespace = namespace
  }

  public func lookup(did: String, now: Date) async throws -> PDSResolutionCacheLookup {
    switch try await cache.lookup(
      StoredResolution.self,
      key: namespace.key(domain: "pds-resolution", identifiers: [did]),
      cacheType: "pds_resolution",
      now: now
    ) {
    case .fresh(let envelope):
      return .fresh(endpoint(from: envelope.value))
    case .stale(let envelope):
      return .stale(endpoint(from: envelope.value))
    case .miss:
      return .miss
    }
  }

  public func storeResolved(did: String, endpoint: String, now: Date) async throws {
    try await cache.store(
      StoredResolution.resolved(endpoint),
      key: namespace.key(domain: "pds-resolution", identifiers: [did]),
      policy: RedisCachePolicy(freshDuration: 30 * 60, hardDuration: 6 * 60 * 60),
      now: now
    )
  }

  public func storeUnresolved(did: String, now: Date) async throws {
    try await cache.store(
      StoredResolution.unresolved,
      key: namespace.key(domain: "pds-resolution", identifiers: [did]),
      policy: RedisCachePolicy(freshDuration: 60, hardDuration: 5 * 60),
      now: now
    )
  }

  public func acquireLease(did: String, ttl: TimeInterval) async throws -> RedisLease? {
    try await leases.acquire(domain: "pds-resolution", resource: did, ttl: ttl)
  }

  public func releaseLease(_ lease: RedisLease) async {
    _ = try? await leases.release(lease)
  }

  private func endpoint(from value: StoredResolution) -> String? {
    switch value {
    case .resolved(let endpoint): endpoint
    case .unresolved: nil
    }
  }
}
