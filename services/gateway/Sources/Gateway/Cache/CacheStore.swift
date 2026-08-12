import Foundation
import GatewayCore

/// PDS-aligned cache freshness knobs tuned for **`repo.getRecord`** overlays.
enum CacheStorePdsTTLs {
  /// TTL that governs read-through staleness for preferences payloads.
  static let preferencesCachedPayloadTTL: TimeInterval = 5 * 60

  /// How long persisted SQLite/Postgres cache rows linger for preferences.
  static let preferencesWriteHorizon: TimeInterval = 30 * 60

  /// Generic **`getRecord`** short cache window used by **`/v1/pds/cache/record`**.
  static let genericRecordTTL: TimeInterval = 2 * 60

  /// Generic cache row eviction horizon stored server-side for non-preference payloads.
  static let genericWriteHorizon: TimeInterval = 20 * 60
}

struct PdsRepoRecordRefreshLease: Sendable, Equatable {
  let key: String
  let owner: String
  let ttlMilliseconds: Int
}

/// Focused cache interface for short-lived `com.atproto.repo.getRecord` JSON blobs.
protocol PdsRepoRecordCacheStore: Actor {

  func cachedPdsRepoRecord(ownerDid: String, scopeKey: String) async throws -> PdsCachedRepoRecordPayload?

  func storePdsRepoRecordPayload(
    ownerDid: String,
    scopeKey: String,
    cid: String?,
    jsonBody: String,
    cachedAt: Date,
    expiresAt: Date
  ) async throws

  func acquirePdsRefreshLease(ownerDid: String, scopeKey: String) async -> PdsRepoRecordRefreshLease?
  func renewPdsRefreshLease(_ lease: PdsRepoRecordRefreshLease) async -> Bool
  func releasePdsRefreshLease(_ lease: PdsRepoRecordRefreshLease) async
}

extension PdsRepoRecordCacheStore {
  func acquirePdsRefreshLease(ownerDid: String, scopeKey: String) async -> PdsRepoRecordRefreshLease? {
    PdsRepoRecordRefreshLease(
      key: "local:\(ownerDid):\(scopeKey)",
      owner: UUID().uuidString.lowercased(),
      ttlMilliseconds: 15_000
    )
  }

  func releasePdsRefreshLease(_ lease: PdsRepoRecordRefreshLease) async {
    _ = lease
  }

  func renewPdsRefreshLease(_ lease: PdsRepoRecordRefreshLease) async -> Bool {
    _ = lease
    return true
  }
}
