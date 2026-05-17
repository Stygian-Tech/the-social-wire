-- PDS-record cache backing `SupabaseCache.cachedPdsRepoRecord` / `storePdsRepoRecordPayload`.
-- Safe to apply on projects that already have discovery + entry caches; only adds the new table.

CREATE TABLE IF NOT EXISTS pds_repo_record_cache (
  owner_did TEXT NOT NULL,
  scope_key TEXT NOT NULL,
  cid TEXT NULL,
  json_body TEXT NOT NULL,
  cached_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (owner_did, scope_key)
);

CREATE INDEX IF NOT EXISTS idx_pds_repo_record_cache_expires_at
  ON pds_repo_record_cache (expires_at);

COMMENT ON TABLE pds_repo_record_cache IS 'Short TTL cache of JSON repo.getRecord payloads; not authoritative.';
