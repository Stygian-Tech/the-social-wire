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

/// Shared cache interface for SQLite + Postgres implementations.
protocol CacheStore: Actor {

  // MARK: - Discovery cache

  func cachedPublications(
    for userDID: String
  ) async throws -> (publications: [DiscoveredPublication], lastRefreshedAt: Date?)?

  func storePublications(
    _ publications: [DiscoveredPublication],
    for userDID: String
  ) async throws

  // MARK: - Entry cache

  func cachedEntry(for entryURI: String) async throws -> EntryDetail?

  func storeEntry(_ entry: EntryDetail) async throws

  // MARK: - Generic **`com.atproto.repo.getRecord`** JSON blobs

  func cachedPdsRepoRecord(ownerDid: String, scopeKey: String) async throws -> PdsCachedRepoRecordPayload?

  func storePdsRepoRecordPayload(
    ownerDid: String,
    scopeKey: String,
    cid: String?,
    jsonBody: String,
    cachedAt: Date,
    expiresAt: Date
  ) async throws
}
