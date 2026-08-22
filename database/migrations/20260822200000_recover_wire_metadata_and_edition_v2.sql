-- Recover expired metadata claims after a worker interruption and identify the
-- bounded Standard Site presentation tie-break used by newly materialized editions.

DROP INDEX IF EXISTS wire_link_metadata_cache_due_idx;

CREATE INDEX wire_link_metadata_cache_due_idx
  ON wire_link_metadata_cache (retry_after, fresh_until, canonical_key)
  WHERE status IN ('pending', 'fresh', 'stale', 'negative', 'retry', 'failed', 'fetching');

ALTER TABLE wire_edition_generations
  ALTER COLUMN algorithm_version SET DEFAULT 'wire-edition-v2';

COMMENT ON TABLE wire_edition_generations IS
  'Deterministic Wire edition materialization pinned to one immutable wire-v1 generation.';
