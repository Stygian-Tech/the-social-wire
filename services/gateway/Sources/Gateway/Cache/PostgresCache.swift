import Foundation
import Logging
import GatewayCore
import PostgresNIO

/// Reads and writes to the hosted Postgres cache tables.
/// This is not the source of truth for any user data — it is a performance cache only.
/// Used in `dev` and `prod` environments; `SQLiteCache` is used for `local`.
actor PostgresCache: PdsRepoRecordCacheStore {
  private let pool: PostgresClient
  private let logger: Logger

  init(pool: PostgresClient, logger: Logger) {
    self.pool = pool
    self.logger = logger
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
