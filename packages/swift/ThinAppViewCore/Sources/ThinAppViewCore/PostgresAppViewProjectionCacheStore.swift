import Foundation
import Logging
import PostgresNIO

public actor PostgresAppViewProjectionCacheStore: AppViewProjectionCacheStore {
  private let pool: PostgresClient
  private let logger: Logger

  public init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
  }

  public func sidebarProjectionCacheEntry(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<String>? {
    let rows = try await pool.query(
      """
      SELECT json_body::text, cached_at, expires_at
      FROM sidebar_projection_cache
      WHERE viewer_did = \(viewerDid)
        AND expires_at > NOW()
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (json, cachedAt, expiresAt) = try row.decode((String, Date, Date).self)
      return AppViewProjectionCacheEntry(
        value: json,
        cachedAt: cachedAt,
        expiresAt: expiresAt
      )
    }
    return nil
  }

  public func storeSidebarProjectionJSON(
    viewerDid: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws {
    let cachedAt = Date()
    try await pool.query(
      """
      INSERT INTO sidebar_projection_cache (viewer_did, json_body, cached_at, expires_at)
      VALUES (\(viewerDid), \(jsonBody)::jsonb, \(cachedAt), \(expiresAt))
      ON CONFLICT (viewer_did)
      DO UPDATE SET
        json_body = EXCLUDED.json_body,
        cached_at = EXCLUDED.cached_at,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }

  public func invalidateSidebarProjection(viewerDid: String) async throws {
    try await pool.query(
      "DELETE FROM sidebar_projection_cache WHERE viewer_did = \(viewerDid)",
      logger: logger
    )
  }

  public func unreadCountsCacheEntry(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<[String: Int]>? {
    let rows = try await pool.query(
      """
      SELECT publication_id, unread_count, cached_at, expires_at
      FROM unread_counts_cache
      WHERE viewer_did = \(viewerDid)
        AND expires_at > NOW()
      """,
      logger: logger
    )
    var counts: [String: Int] = [:]
    var sawRow = false
    var oldestCachedAt: Date?
    var earliestExpiresAt: Date?
    for try await row in rows {
      sawRow = true
      let (publicationId, unreadCount, cachedAt, expiresAt) = try row.decode(
        (String, Int, Date, Date).self
      )
      counts[publicationId] = max(0, unreadCount)
      oldestCachedAt = min(oldestCachedAt ?? cachedAt, cachedAt)
      earliestExpiresAt = min(earliestExpiresAt ?? expiresAt, expiresAt)
    }
    guard sawRow, let oldestCachedAt, let earliestExpiresAt else { return nil }
    return AppViewProjectionCacheEntry(
      value: counts,
      cachedAt: oldestCachedAt,
      expiresAt: earliestExpiresAt
    )
  }

  public func storeUnreadCounts(
    viewerDid: String,
    counts: [String: Int],
    expiresAt: Date
  ) async throws {
    let cachedAt = Date()
    for (publicationId, unreadCount) in counts {
      let cachedUnreadCount = max(0, unreadCount)
      try await pool.query(
        """
        INSERT INTO unread_counts_cache
          (viewer_did, publication_id, unread_count, cached_at, expires_at)
        VALUES
          (\(viewerDid), \(publicationId), \(cachedUnreadCount), \(cachedAt), \(expiresAt))
        ON CONFLICT (viewer_did, publication_id)
        DO UPDATE SET
          unread_count = EXCLUDED.unread_count,
          cached_at = EXCLUDED.cached_at,
          expires_at = EXCLUDED.expires_at
        """,
        logger: logger
      )
    }
  }

  public func invalidateUnreadCounts(viewerDid: String, publicationId: String?) async throws {
    if let publicationId {
      try await pool.query(
        """
        DELETE FROM unread_counts_cache
        WHERE viewer_did = \(viewerDid)
          AND publication_id = \(publicationId)
        """,
        logger: logger
      )
    } else {
      try await pool.query(
        "DELETE FROM unread_counts_cache WHERE viewer_did = \(viewerDid)",
        logger: logger
      )
    }
  }

  public func firstPageCacheEntry(
    viewerDid: String,
    publicationId: String
  ) async throws -> AppViewProjectionCacheEntry<String>? {
    let rows = try await pool.query(
      """
      SELECT json_body::text, cached_at, expires_at
      FROM first_page_cache
      WHERE viewer_did = \(viewerDid)
        AND publication_id = \(publicationId)
        AND expires_at > NOW()
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let (json, cachedAt, expiresAt) = try row.decode((String, Date, Date).self)
      return AppViewProjectionCacheEntry(
        value: json,
        cachedAt: cachedAt,
        expiresAt: expiresAt
      )
    }
    return nil
  }

  public func storeFirstPageJSON(
    viewerDid: String,
    publicationId: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws {
    let cachedAt = Date()
    try await pool.query(
      """
      INSERT INTO first_page_cache
        (viewer_did, publication_id, json_body, cached_at, expires_at)
      VALUES
        (\(viewerDid), \(publicationId), \(jsonBody)::jsonb, \(cachedAt), \(expiresAt))
      ON CONFLICT (viewer_did, publication_id)
      DO UPDATE SET
        json_body = EXCLUDED.json_body,
        cached_at = EXCLUDED.cached_at,
        expires_at = EXCLUDED.expires_at
      """,
      logger: logger
    )
  }

  public func invalidateFirstPage(viewerDid: String, publicationId: String?) async throws {
    if let publicationId {
      try await pool.query(
        """
        DELETE FROM first_page_cache
        WHERE viewer_did = \(viewerDid)
          AND publication_id = \(publicationId)
        """,
        logger: logger
      )
    } else {
      try await pool.query(
        "DELETE FROM first_page_cache WHERE viewer_did = \(viewerDid)",
        logger: logger
      )
    }
  }

  public func invalidateFirstPageForAllViewers(publicationId: String) async throws {
    try await pool.query(
      "DELETE FROM first_page_cache WHERE publication_id = \(publicationId)",
      logger: logger
    )
  }

  public func invalidateAllProjectionCaches() async throws {
    try await pool.query("DELETE FROM sidebar_projection_cache", logger: logger)
    try await pool.query("DELETE FROM unread_counts_cache", logger: logger)
    try await pool.query("DELETE FROM first_page_cache", logger: logger)
  }

  public func deleteExpiredProjectionCaches(before: Date, batchSize: Int) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    var deleted = 0
    deleted += try await deleteExpiredRows(
      from: "sidebar_projection_cache", before: before, batchSize: batchSize)
    deleted += try await deleteExpiredRows(
      from: "unread_counts_cache", before: before, batchSize: batchSize)
    deleted += try await deleteExpiredRows(
      from: "first_page_cache", before: before, batchSize: batchSize)
    return deleted
  }

  private func deleteExpiredRows(
    from table: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int {
    var deleted = 0
    switch table {
    case "sidebar_projection_cache":
      let rows = try await pool.query(
        """
        WITH doomed AS (
          SELECT ctid FROM sidebar_projection_cache
          WHERE expires_at <= \(before)
          ORDER BY expires_at, viewer_did
          LIMIT \(batchSize)
        )
        DELETE FROM sidebar_projection_cache AS target USING doomed
        WHERE target.ctid = doomed.ctid
        RETURNING 1
        """,
        logger: logger
      )
      for try await _ in rows { deleted += 1 }
    case "unread_counts_cache":
      let rows = try await pool.query(
        """
        WITH doomed AS (
          SELECT ctid FROM unread_counts_cache
          WHERE expires_at <= \(before)
          ORDER BY expires_at, viewer_did, publication_id
          LIMIT \(batchSize)
        )
        DELETE FROM unread_counts_cache AS target USING doomed
        WHERE target.ctid = doomed.ctid
        RETURNING 1
        """,
        logger: logger
      )
      for try await _ in rows { deleted += 1 }
    case "first_page_cache":
      let rows = try await pool.query(
        """
        WITH doomed AS (
          SELECT ctid FROM first_page_cache
          WHERE expires_at <= \(before)
          ORDER BY expires_at, viewer_did, publication_id
          LIMIT \(batchSize)
        )
        DELETE FROM first_page_cache AS target USING doomed
        WHERE target.ctid = doomed.ctid
        RETURNING 1
        """,
        logger: logger
      )
      for try await _ in rows { deleted += 1 }
    default:
      break
    }
    return deleted
  }
}
