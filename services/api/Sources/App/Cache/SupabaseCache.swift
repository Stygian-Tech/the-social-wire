import Foundation
import GatewayCore
import Logging
import PostgresNIO

/// Reads and writes to the Supabase Postgres cache tables.
/// This is not the source of truth for any user data — it is a performance cache only.
/// Used in `dev` and `prod` environments; `SQLiteCache` is used for `local`.
actor SupabaseCache: CacheStore {
  private let pool: PostgresClient
  private let logger: Logger

  // Cache TTL: re-scan after 6 hours
  static let discoveryTTL: TimeInterval = 6 * 60 * 60
  // Entry cache TTL: 30 minutes
  static let entryTTL: TimeInterval = 30 * 60

  init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  // MARK: - Discovery cache

  /// Returns cached publications for a user, or nil if the cache is empty / stale.
  func cachedPublications(for userDID: String) async throws -> (publications: [DiscoveredPublication], lastRefreshedAt: Date?)? {
    let rows = try await pool.query(
      """
      SELECT publication_id, author_did, author_handle, title, avatar_url, discovered_at
      FROM discovery_cache
      WHERE user_did = \(userDID)
      ORDER BY discovered_at DESC
      """,
      logger: logger
    )

    var publications: [DiscoveredPublication] = []
    var latestDate: Date?

    for try await row in rows {
      let (publicationId, authorDid, authorHandle, title, avatarUrl, discoveredAt) =
        try row.decode((String, String, String?, String, String?, Date).self)
      publications.append(DiscoveredPublication(
        publicationId: publicationId,
        authorDid: authorDid,
        authorHandle: authorHandle,
        title: title,
        avatarUrl: avatarUrl,
        discoveredAt: discoveredAt
      ))
      if latestDate == nil || discoveredAt > latestDate! {
        latestDate = discoveredAt
      }
    }

    guard !publications.isEmpty else { return nil }

    // Check TTL
    if let latest = latestDate, Date().timeIntervalSince(latest) > Self.discoveryTTL {
      logger.info("Discovery cache is stale for user", metadata: ["did": "\(userDID)"])
      return nil
    }

    return (publications, latestDate)
  }

  /// Replaces the discovery cache for a user with fresh results.
  func storePublications(_ publications: [DiscoveredPublication], for userDID: String) async throws {
    // Delete existing cache for this user
    try await pool.query(
      "DELETE FROM discovery_cache WHERE user_did = \(userDID)",
      logger: logger
    )

    // Insert fresh results
    for pub in publications {
      try await pool.query(
        """
        INSERT INTO discovery_cache
          (user_did, publication_id, author_did, author_handle, title, avatar_url, discovered_at)
        VALUES
          (\(userDID), \(pub.publicationId), \(pub.authorDid), \(pub.authorHandle), \(pub.title), \(pub.avatarUrl), \(pub.discoveredAt))
        ON CONFLICT (user_did, publication_id)
        DO UPDATE SET
          author_handle = EXCLUDED.author_handle,
          title = EXCLUDED.title,
          avatar_url = EXCLUDED.avatar_url,
          discovered_at = EXCLUDED.discovered_at
        """,
        logger: logger
      )
    }

    logger.info("Stored \(publications.count) publications in discovery cache", metadata: ["did": "\(userDID)"])
  }

  // MARK: - Entry cache

  /// Returns a cached entry detail, or nil if not cached / stale.
  func cachedEntry(for entryURI: String) async throws -> EntryDetail? {
    let rows = try await pool.query(
      """
      SELECT entry_uri, title, content, original_url, published_at, cached_at
      FROM entry_cache
      WHERE entry_uri = \(entryURI)
      LIMIT 1
      """,
      logger: logger
    )

    for try await row in rows {
      let (entryUri, title, content, originalUrl, publishedAt, cachedAt) =
        try row.decode((String, String, String, String?, Date?, Date).self)

      // Check TTL
      if Date().timeIntervalSince(cachedAt) > Self.entryTTL {
        return nil
      }

      return EntryDetail(
        entryId: entryUri,
        title: title,
        publishedAt: publishedAt ?? cachedAt,
        contentHtml: content,
        originalUrl: originalUrl
      )
    }

    return nil
  }

  /// Stores an entry in the cache.
  func storeEntry(_ entry: EntryDetail) async throws {
    try await pool.query(
      """
      INSERT INTO entry_cache (entry_uri, title, content, original_url, published_at, cached_at)
      VALUES (\(entry.entryId), \(entry.title), \(entry.contentHtml), \(entry.originalUrl), \(entry.publishedAt), NOW())
      ON CONFLICT (entry_uri)
      DO UPDATE SET
        title = EXCLUDED.title,
        content = EXCLUDED.content,
        original_url = EXCLUDED.original_url,
        published_at = EXCLUDED.published_at,
        cached_at = NOW()
      """,
      logger: logger
    )
  }

  // MARK: - Repo record payloads

  func cachedPdsRepoRecord(ownerDid: String, scopeKey: String) async throws -> PdsCachedRepoRecordPayload? {
    let rows = try await pool.query(
      """
      SELECT cid, json_body, cached_at
      FROM pds_repo_record_cache
      WHERE owner_did = \(ownerDid)
        AND scope_key = \(scopeKey)
        AND expires_at > NOW()
      LIMIT 1
      """,
      logger: logger
    )

    for try await row in rows {
      let (cid, jsonBody, cachedAt) = try row.decode((String?, String, Date).self)
      return PdsCachedRepoRecordPayload(cid: cid, jsonBody: jsonBody, cachedAt: cachedAt)
    }

    return nil
  }

  func storePdsRepoRecordPayload(
    ownerDid: String,
    scopeKey: String,
    cid: String?,
    jsonBody: String,
    cachedAt: Date,
    expiresAt: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO pds_repo_record_cache
        (owner_did, scope_key, cid, json_body, cached_at, expires_at)
      VALUES
        (\(ownerDid), \(scopeKey), \(cid), \(jsonBody), \(cachedAt), \(expiresAt))
      ON CONFLICT (owner_did, scope_key)
      DO UPDATE SET
        cid = EXCLUDED.cid,
        json_body = EXCLUDED.json_body,
        cached_at = EXCLUDED.cached_at,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }
}
