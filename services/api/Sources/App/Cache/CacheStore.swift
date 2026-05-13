import Foundation

/// Common interface for the discovery and entry caches.
///
/// Two implementations exist:
/// - `SupabaseCache` — Postgres via `postgres-nio` (dev / prod)
/// - `SQLiteCache`   — on-disk SQLite via GRDB (local development)
///
/// `main.swift` selects the backend based on `APP_ENV`:
///   - `local`     → SQLiteCache (no Supabase required)
///   - `dev`/`prod`→ SupabaseCache
protocol CacheStore: Actor {

  // MARK: - Discovery cache

  /// Returns cached publications for a user, or `nil` if empty or stale.
  func cachedPublications(
    for userDID: String
  ) async throws -> (publications: [DiscoveredPublication], lastRefreshedAt: Date?)?

  /// Replaces the discovery cache for a user with fresh results.
  func storePublications(
    _ publications: [DiscoveredPublication],
    for userDID: String
  ) async throws

  // MARK: - Entry cache

  /// Returns a cached entry, or `nil` if missing or stale.
  func cachedEntry(for entryURI: String) async throws -> EntryDetail?

  /// Stores an entry in the cache.
  func storeEntry(_ entry: EntryDetail) async throws
}
