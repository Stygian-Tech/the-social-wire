@preconcurrency import GRDB
import Foundation
import Logging

public actor SQLiteAppViewProjectionCacheStore: AppViewProjectionCacheStore {
  private let db: DatabasePool
  private let logger: Logger

  public init(path dbPath: String, logger: Logger) throws {
    self.logger = logger
    var config = Configuration()
    config.label = "com.thesocialwire.appview-projection-cache"
    self.db = try DatabasePool(path: dbPath, configuration: config)
    try db.write { db in
      try Self.migrate(db)
    }
  }

  public init(db: DatabasePool, logger: Logger) throws {
    self.db = db
    self.logger = logger
    try db.write { db in
      try Self.migrate(db)
    }
  }

  private static func migrate(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS sidebar_projection_cache (
        viewer_did TEXT PRIMARY KEY,
        json_body TEXT NOT NULL,
        cached_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      );
      """)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_sidebar_projection_cache_expires
        ON sidebar_projection_cache (expires_at);
      """)
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS unread_counts_cache (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        unread_count INTEGER NOT NULL,
        cached_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      );
      """)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_unread_counts_cache_viewer_expires
        ON unread_counts_cache (viewer_did, expires_at);
      """)
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS first_page_cache (
        viewer_did TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        json_body TEXT NOT NULL,
        cached_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (viewer_did, publication_id)
      );
      """)
    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_first_page_cache_viewer_expires
        ON first_page_cache (viewer_did, expires_at);
      """)
  }

  public func cachedSidebarProjectionJSON(viewerDid: String) async throws -> String? {
    try await db.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT json_body
          FROM sidebar_projection_cache
          WHERE viewer_did = ?
            AND expires_at > ?
          LIMIT 1
          """,
        arguments: [viewerDid, Self.isoString(from: Date())]
      )
    }
  }

  public func storeSidebarProjectionJSON(
    viewerDid: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws {
    let cachedAt = Self.isoString(from: Date())
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO sidebar_projection_cache (viewer_did, json_body, cached_at, expires_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT (viewer_did) DO UPDATE SET
            json_body = excluded.json_body,
            cached_at = excluded.cached_at,
            expires_at = excluded.expires_at
          """,
        arguments: [viewerDid, jsonBody, cachedAt, Self.isoString(from: expiresAt)]
      )
    }
  }

  public func invalidateSidebarProjection(viewerDid: String) async throws {
    try await db.write { db in
      try db.execute(
        sql: "DELETE FROM sidebar_projection_cache WHERE viewer_did = ?",
        arguments: [viewerDid]
      )
    }
  }

  public func cachedUnreadCounts(viewerDid: String) async throws -> [String: Int]? {
    try await db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT publication_id, unread_count
          FROM unread_counts_cache
          WHERE viewer_did = ?
            AND expires_at > ?
          """,
        arguments: [viewerDid, Self.isoString(from: Date())]
      )
      var counts: [String: Int] = [:]
      for row in rows {
        let publicationId: String = row["publication_id"]
        let unreadCount: Int = row["unread_count"]
        if unreadCount > 0 {
          counts[publicationId] = unreadCount
        }
      }
      return counts.isEmpty ? nil : counts
    }
  }

  public func storeUnreadCounts(
    viewerDid: String,
    counts: [String: Int],
    expiresAt: Date
  ) async throws {
    let cachedAt = Self.isoString(from: Date())
    let expires = Self.isoString(from: expiresAt)
    try await db.write { db in
      for (publicationId, unreadCount) in counts where unreadCount > 0 {
        try db.execute(
          sql: """
            INSERT INTO unread_counts_cache
              (viewer_did, publication_id, unread_count, cached_at, expires_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
              unread_count = excluded.unread_count,
              cached_at = excluded.cached_at,
              expires_at = excluded.expires_at
            """,
          arguments: [viewerDid, publicationId, unreadCount, cachedAt, expires]
        )
      }
    }
  }

  public func invalidateUnreadCounts(viewerDid: String, publicationId: String?) async throws {
    try await db.write { db in
      if let publicationId {
        try db.execute(
          sql: """
            DELETE FROM unread_counts_cache
            WHERE viewer_did = ? AND publication_id = ?
            """,
          arguments: [viewerDid, publicationId]
        )
      } else {
        try db.execute(
          sql: "DELETE FROM unread_counts_cache WHERE viewer_did = ?",
          arguments: [viewerDid]
        )
      }
    }
  }

  public func cachedFirstPageJSON(viewerDid: String, publicationId: String) async throws -> String? {
    try await db.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT json_body
          FROM first_page_cache
          WHERE viewer_did = ?
            AND publication_id = ?
            AND expires_at > ?
          LIMIT 1
          """,
        arguments: [viewerDid, publicationId, Self.isoString(from: Date())]
      )
    }
  }

  public func storeFirstPageJSON(
    viewerDid: String,
    publicationId: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws {
    let cachedAt = Self.isoString(from: Date())
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO first_page_cache
            (viewer_did, publication_id, json_body, cached_at, expires_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (viewer_did, publication_id) DO UPDATE SET
            json_body = excluded.json_body,
            cached_at = excluded.cached_at,
            expires_at = excluded.expires_at
          """,
        arguments: [
          viewerDid,
          publicationId,
          jsonBody,
          cachedAt,
          Self.isoString(from: expiresAt),
        ]
      )
    }
  }

  public func invalidateFirstPage(viewerDid: String, publicationId: String?) async throws {
    try await db.write { db in
      if let publicationId {
        try db.execute(
          sql: """
            DELETE FROM first_page_cache
            WHERE viewer_did = ? AND publication_id = ?
            """,
          arguments: [viewerDid, publicationId]
        )
      } else {
        try db.execute(
          sql: "DELETE FROM first_page_cache WHERE viewer_did = ?",
          arguments: [viewerDid]
        )
      }
    }
  }

  public func deleteExpiredProjectionCaches(before: Date) async throws -> Int {
    let cutoff = Self.isoString(from: before)
    return try await db.write { db in
      var deleted = 0
      for table in ["sidebar_projection_cache", "unread_counts_cache", "first_page_cache"] {
        try db.execute(sql: "DELETE FROM \(table) WHERE expires_at <= ?", arguments: [cutoff])
        deleted += db.changesCount
      }
      return deleted
    }
  }

  private static func isoString(from date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
