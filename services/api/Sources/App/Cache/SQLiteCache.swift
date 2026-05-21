@preconcurrency import GRDB
import GatewayCore
import Foundation
import Logging

/// SQLite-backed implementation of `CacheStore`.
///
/// Used in `local` mode so the service runs without a Supabase/Postgres
/// connection. The database file is created automatically at `dbPath`
/// if it doesn't exist.
///
/// Schema mirrors the Supabase migration in `infra/docker/`.
actor SQLiteCache: CacheStore {

  // Cache TTLs — same as SupabaseCache
  static let discoveryTTL: TimeInterval = 6 * 60 * 60   // 6 hours
  static let entryTTL: TimeInterval     = 30 * 60        // 30 minutes

  private let db: DatabasePool
  private let logger: Logger

  // MARK: - Init

  init(path dbPath: String, logger: Logger) throws {
    self.logger = logger

    var config = Configuration()
    config.label = "com.thesocialwire.sqlite"
    self.db = try DatabasePool(path: dbPath, configuration: config)

    // Run migrations synchronously during initialisation (before the actor
    // is used, so there's no concurrency concern here).
    try self.db.write { db in
      try SQLiteCache.migrate(db)
    }

    logger.info("SQLiteCache initialised", metadata: ["path": "\(dbPath)"])
  }

  // MARK: - Schema migrations

  private static func migrate(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS discovery_cache (
        user_did       TEXT NOT NULL,
        publication_id TEXT NOT NULL,
        author_did     TEXT NOT NULL,
        author_handle  TEXT,
        title          TEXT NOT NULL,
        avatar_url     TEXT,
        discovered_at  TEXT NOT NULL,
        PRIMARY KEY (user_did, publication_id)
      );
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS entry_cache (
        entry_uri    TEXT PRIMARY KEY,
        title        TEXT NOT NULL,
        content      TEXT NOT NULL,
        original_url TEXT,
        published_at TEXT,
        cached_at    TEXT NOT NULL
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_discovery_user_did
        ON discovery_cache(user_did);
      """)

    try db.execute(sql: """
      CREATE TABLE IF NOT EXISTS pds_repo_record_cache (
        owner_did TEXT NOT NULL,
        scope_key TEXT NOT NULL,
        cid TEXT,
        json_body TEXT NOT NULL,
        cached_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY (owner_did, scope_key)
      );
      """)

    try db.execute(sql: """
      CREATE INDEX IF NOT EXISTS idx_pds_record_expires_at
        ON pds_repo_record_cache(expires_at);
      """)
  }

  // MARK: - CacheStore: Discovery

  func cachedPublications(
    for userDID: String
  ) async throws -> (publications: [DiscoveredPublication], lastRefreshedAt: Date?)? {

    let rowValues: [(String, String, String?, String, String?, String)] = try await db.read { db in
      let rows = try Row.fetchAll(db, sql: """
        SELECT publication_id, author_did, author_handle, title, avatar_url, discovered_at
        FROM discovery_cache
        WHERE user_did = ?
        ORDER BY discovered_at DESC
        """, arguments: [userDID])
      return rows.map { row in
        (
          row["publication_id"],
          row["author_did"],
          row["author_handle"],
          row["title"],
          row["avatar_url"],
          row["discovered_at"]
        )
      }
    }

    guard !rowValues.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    var publications: [DiscoveredPublication] = []
    var latestDate: Date?

    for (publicationId, authorDid, authorHandle, title, avatarUrl, discoveredAtStr) in rowValues {
      let discoveredAt = iso.date(from: discoveredAtStr) ?? Date(timeIntervalSince1970: 0)

      publications.append(DiscoveredPublication(
        publicationId: publicationId,
        authorDid:     authorDid,
        authorHandle:  authorHandle,
        title:         title,
        avatarUrl:     avatarUrl,
        discoveredAt:  discoveredAt
      ))

      if latestDate == nil || discoveredAt > latestDate! {
        latestDate = discoveredAt
      }
    }

    // Stale-check
    if let latest = latestDate,
       Date().timeIntervalSince(latest) > Self.discoveryTTL {
      logger.debug("Discovery cache stale", metadata: ["did": .string(userDID)])
      return nil
    }

    return (publications, latestDate)
  }

  func storePublications(
    _ publications: [DiscoveredPublication],
    for userDID: String
  ) async throws {

    // Convert Dates → ISO 8601 strings BEFORE entering the @Sendable write closure,
    // since ISO8601DateFormatter is not Sendable and cannot be captured by async closures.
    let iso = ISO8601DateFormatter()
    let rows: [(String, String, String, String?, String, String?, String)] = publications.map { pub in
      (
        userDID,
        pub.publicationId,
        pub.authorDid,
        pub.authorHandle,
        pub.title,
        pub.avatarUrl,
        iso.string(from: pub.discoveredAt)
      )
    }

    try await db.write { db in
      // Replace all rows for this user
      try db.execute(sql: "DELETE FROM discovery_cache WHERE user_did = ?",
                     arguments: [userDID])

      for (did, pubId, authorDid, authorHandle, title, avatarUrl, discoveredAt) in rows {
        try db.execute(sql: """
          INSERT INTO discovery_cache
            (user_did, publication_id, author_did, author_handle, title, avatar_url, discovered_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (user_did, publication_id) DO UPDATE SET
            author_handle = excluded.author_handle,
            title         = excluded.title,
            avatar_url    = excluded.avatar_url,
            discovered_at = excluded.discovered_at
          """,
          arguments: [did, pubId, authorDid, authorHandle, title, avatarUrl, discoveredAt])
      }
    }

    logger.info(
      "Stored \(publications.count) publications in SQLite cache",
      metadata: ["did": .string(userDID)]
    )
  }

  // MARK: - CacheStore: Entry

  func cachedEntry(for entryURI: String) async throws -> EntryDetail? {
    let iso = ISO8601DateFormatter()

    let fields: (entryUri: String, title: String, content: String, originalUrl: String?, publishedAt: String?, cachedAt: String)? =
      try await db.read { db in
        guard let row = try Row.fetchOne(db, sql: """
          SELECT entry_uri, title, content, original_url, published_at, cached_at
          FROM entry_cache
          WHERE entry_uri = ?
          LIMIT 1
          """, arguments: [entryURI])
        else { return nil }

        return (
          row["entry_uri"],
          row["title"],
          row["content"],
          row["original_url"],
          row["published_at"],
          row["cached_at"]
        )
      }

    guard let fields else { return nil }

    let cachedAt = iso.date(from: fields.cachedAt) ?? Date(timeIntervalSince1970: 0)

    guard Date().timeIntervalSince(cachedAt) <= Self.entryTTL else {
      return nil
    }

    let publishedAt = fields.publishedAt.flatMap { iso.date(from: $0) } ?? cachedAt

    return EntryDetail(
      entryId:     fields.entryUri,
      title:       fields.title,
      publishedAt: publishedAt,
      contentHtml: fields.content,
      originalUrl: fields.originalUrl
    )
  }

  func storeEntry(_ entry: EntryDetail) async throws {
    let iso = ISO8601DateFormatter()
    let now = iso.string(from: Date())
    let publishedAt = iso.string(from: entry.publishedAt)

    try await db.write { db in
      try db.execute(sql: """
        INSERT INTO entry_cache (entry_uri, title, content, original_url, published_at, cached_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (entry_uri) DO UPDATE SET
          title        = excluded.title,
          content      = excluded.content,
          original_url = excluded.original_url,
          published_at = excluded.published_at,
          cached_at    = excluded.cached_at
        """,
        arguments: [
          entry.entryId,
          entry.title,
          entry.contentHtml,
          entry.originalUrl,
          publishedAt,
          now,
        ])
    }
  }

  // MARK: - **`com.atproto.repo.getRecord`** payload cache

  func cachedPdsRepoRecord(ownerDid: String, scopeKey: String) async throws -> PdsCachedRepoRecordPayload? {
    let iso = ISO8601DateFormatter()

    let fields: (cid: String?, jsonBody: String, cachedAt: String, expiresAt: String)? =
      try await db.read { db in
        guard let row = try Row.fetchOne(db, sql: """
          SELECT cid, json_body, cached_at, expires_at
          FROM pds_repo_record_cache
          WHERE owner_did = ? AND scope_key = ?
          LIMIT 1
          """,
          arguments: [ownerDid, scopeKey])
        else { return nil }

        return (
          row["cid"],
          row["json_body"],
          row["cached_at"],
          row["expires_at"]
        )
      }

    guard let fields else { return nil }

    guard let expiresAt = iso.date(from: fields.expiresAt) else { return nil }
    if expiresAt <= Date() {
      try await db.write { db in
        try db.execute(sql: """
          DELETE FROM pds_repo_record_cache
          WHERE owner_did = ? AND scope_key = ?
          """, arguments: [ownerDid, scopeKey])
      }
      return nil
    }

    let cachedAt = iso.date(from: fields.cachedAt) ?? Date(timeIntervalSince1970: 0)

    return PdsCachedRepoRecordPayload(cid: fields.cid, jsonBody: fields.jsonBody, cachedAt: cachedAt)
  }

  func storePdsRepoRecordPayload(
    ownerDid: String,
    scopeKey: String,
    cid: String?,
    jsonBody: String,
    cachedAt: Date,
    expiresAt: Date
  ) async throws {

    let iso = ISO8601DateFormatter()
    let cachedAtIso = iso.string(from: cachedAt)
    let expiresAtIso = iso.string(from: expiresAt)
    try await db.write { db in
      try db.execute(sql: """
        INSERT INTO pds_repo_record_cache
          (owner_did, scope_key, cid, json_body, cached_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (owner_did, scope_key) DO UPDATE SET
          cid       = excluded.cid,
          json_body = excluded.json_body,
          cached_at = excluded.cached_at,
          expires_at= excluded.expires_at
        """,
        arguments: [
          ownerDid,
          scopeKey,
          cid,
          jsonBody,
          cachedAtIso,
          expiresAtIso,
        ])
    }
  }
}
