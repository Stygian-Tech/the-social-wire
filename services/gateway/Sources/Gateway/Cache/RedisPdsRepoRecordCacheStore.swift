import Foundation
import GatewayCore
import Logging
import SocialWireRedis

actor RedisPdsRepoRecordCacheStore: PdsRepoRecordCacheStore {
  private let cache: RedisCacheClient
  private let leases: RedisLeaseCoordinator
  private let namespace: RedisKeyNamespace
  private let logger: Logger
  private let telemetry: RedisTelemetrySink?

  init(
    commands: any RedisCommandClient,
    environment: String,
    logger: Logger,
    telemetry: RedisTelemetrySink? = nil
  ) {
    let namespace = RedisKeyNamespace(environment: environment)
    self.cache = RedisCacheClient(commands: commands, telemetry: telemetry)
    self.leases = RedisLeaseCoordinator(commands: commands, namespace: namespace, telemetry: telemetry)
    self.namespace = namespace
    self.logger = logger
    self.telemetry = telemetry
  }

  func cachedPdsRepoRecord(
    ownerDid: String,
    scopeKey: String
  ) async throws -> PdsCachedRepoRecordPayload? {
    do {
      return switch try await cache.lookup(
        PdsCachedRepoRecordPayload.self,
        key: key(ownerDid: ownerDid, scopeKey: scopeKey),
        cacheType: "pds_record"
      ) {
      case .fresh(let envelope), .stale(let envelope): envelope.value
      case .miss: nil
      }
    } catch {
      telemetry?(.init(kind: .cacheLookup, operation: "pds_record", outcome: "fallback"))
      logger.warning("Redis PDS cache lookup failed; falling through to PDS", metadata: [
        "error_category": .string("command_failed")
      ])
      return nil
    }
  }

  func storePdsRepoRecordPayload(
    ownerDid: String,
    scopeKey: String,
    cid: String?,
    jsonBody: String,
    cachedAt: Date,
    expiresAt: Date
  ) async throws {
    _ = expiresAt
    let isPreferences = scopeKey.hasPrefix("\(PublicationLexicons.preferences):")
    let policy = RedisCachePolicy(
      freshDuration: isPreferences
        ? CacheStorePdsTTLs.preferencesCachedPayloadTTL
        : CacheStorePdsTTLs.genericRecordTTL,
      hardDuration: isPreferences
        ? CacheStorePdsTTLs.preferencesWriteHorizon
        : CacheStorePdsTTLs.genericWriteHorizon
    )
    do {
      try await cache.store(
        PdsCachedRepoRecordPayload(cid: cid, jsonBody: jsonBody, cachedAt: cachedAt),
        key: key(ownerDid: ownerDid, scopeKey: scopeKey),
        policy: policy,
        now: cachedAt
      )
    } catch {
      logger.warning("Redis PDS cache store failed; response remains authoritative", metadata: [
        "error_category": .string("command_failed")
      ])
    }
  }

  func acquirePdsRefreshLease(
    ownerDid: String,
    scopeKey: String
  ) async -> PdsRepoRecordRefreshLease? {
    do {
      guard let lease = try await leases.acquire(
        domain: "pds",
        resource: "\(ownerDid):\(scopeKey)",
        ttl: 15
      ) else { return nil }
      return PdsRepoRecordRefreshLease(
        key: lease.key,
        owner: lease.owner,
        ttlMilliseconds: lease.ttlMilliseconds
      )
    } catch {
      return PdsRepoRecordRefreshLease(
        key: "",
        owner: UUID().uuidString.lowercased(),
        ttlMilliseconds: 15_000
      )
    }
  }

  func releasePdsRefreshLease(_ lease: PdsRepoRecordRefreshLease) async {
    guard !lease.key.isEmpty else { return }
    _ = try? await leases.release(
      RedisLease(key: lease.key, owner: lease.owner, ttlMilliseconds: lease.ttlMilliseconds)
    )
  }

  func renewPdsRefreshLease(_ lease: PdsRepoRecordRefreshLease) async -> Bool {
    guard !lease.key.isEmpty else { return true }
    return (try? await leases.renew(
      RedisLease(key: lease.key, owner: lease.owner, ttlMilliseconds: lease.ttlMilliseconds)
    )) ?? false
  }

  private func key(ownerDid: String, scopeKey: String) -> String {
    namespace.key(domain: "pds", identifiers: [ownerDid, scopeKey])
  }
}
