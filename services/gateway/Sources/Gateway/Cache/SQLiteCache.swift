@preconcurrency import GRDB
import Foundation
import GatewayCore
import Logging

/// SQLite-backed implementation of `CacheStore`.
///
/// Used in `local` mode so the service runs without hosted Postgres
/// connection. The database file is created automatically at `dbPath`
/// if it doesn't exist.
///
/// Schema mirrors the Postgres migrations in `database/migrations/`.
actor SQLiteCache: PdsRepoRecordCacheStore {
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
