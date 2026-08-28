-- socialwire:transaction=off

ALTER TABLE wire_link_metadata_cache
  ADD COLUMN IF NOT EXISTS language_code TEXT,
  ADD COLUMN IF NOT EXISTS language_checked_at TIMESTAMPTZ;

SET lock_timeout = '5s';
SET statement_timeout = '30min';

CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_link_metadata_cache_language_backfill_idx
  ON wire_link_metadata_cache (canonical_key)
  WHERE source = 'open_graph'
    AND status IN ('fresh', 'stale')
    AND language_checked_at IS NULL;

RESET statement_timeout;
RESET lock_timeout;

COMMENT ON COLUMN wire_link_metadata_cache.language_code IS
  'Normalized primary article language declared by the fetched page, when available.';
COMMENT ON COLUMN wire_link_metadata_cache.language_checked_at IS
  'Last successful full-body metadata fetch that evaluated article language declarations.';
