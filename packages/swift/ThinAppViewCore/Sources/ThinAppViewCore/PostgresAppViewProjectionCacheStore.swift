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

  public func cachedSidebarProjectionJSON(viewerDid: String) async throws -> String? {
    let rows = try await pool.query(
      """
      SELECT json_body::text
      FROM sidebar_projection_cache
      WHERE viewer_did = \(viewerDid)
        AND expires_at > NOW()
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode(String.self)
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

  public func cachedUnreadCounts(viewerDid: String) async throws -> [String: Int]? {
    let rows = try await pool.query(
      """
      SELECT publication_id, unread_count
      FROM unread_counts_cache
      WHERE viewer_did = \(viewerDid)
        AND expires_at > NOW()
      """,
      logger: logger
    )
    var counts: [String: Int] = [:]
    for try await row in rows {
      let (publicationId, unreadCount) = try row.decode((String, Int).self)
      if unreadCount > 0 {
        counts[publicationId] = unreadCount
      }
    }
    return counts.isEmpty ? nil : counts
  }

  public func storeUnreadCounts(
    viewerDid: String,
    counts: [String: Int],
    expiresAt: Date
  ) async throws {
    let cachedAt = Date()
    for (publicationId, unreadCount) in counts where unreadCount > 0 {
      try await pool.query(
        """
        INSERT INTO unread_counts_cache
          (viewer_did, publication_id, unread_count, cached_at, expires_at)
        VALUES
          (\(viewerDid), \(publicationId), \(unreadCount), \(cachedAt), \(expiresAt))
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

  public func cachedFirstPageJSON(viewerDid: String, publicationId: String) async throws -> String? {
    let rows = try await pool.query(
      """
      SELECT json_body::text
      FROM first_page_cache
      WHERE viewer_did = \(viewerDid)
        AND publication_id = \(publicationId)
        AND expires_at > NOW()
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try row.decode(String.self)
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

  public func deleteExpiredProjectionCaches(before: Date) async throws -> Int {
    var deleted = 0
    deleted += try await deleteExpiredRows(from: "sidebar_projection_cache", before: before)
    deleted += try await deleteExpiredRows(from: "unread_counts_cache", before: before)
    deleted += try await deleteExpiredRows(from: "first_page_cache", before: before)
    return deleted
  }

  private func deleteExpiredRows(from table: String, before: Date) async throws -> Int {
    var deleted = 0
    switch table {
    case "sidebar_projection_cache":
      let rows = try await pool.query(
        """
        DELETE FROM sidebar_projection_cache
        WHERE expires_at <= \(before)
        RETURNING 1
        """,
        logger: logger
      )
      for try await _ in rows { deleted += 1 }
    case "unread_counts_cache":
      let rows = try await pool.query(
        """
        DELETE FROM unread_counts_cache
        WHERE expires_at <= \(before)
        RETURNING 1
        """,
        logger: logger
      )
      for try await _ in rows { deleted += 1 }
    case "first_page_cache":
      let rows = try await pool.query(
        """
        DELETE FROM first_page_cache
        WHERE expires_at <= \(before)
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
