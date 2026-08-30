-- socialwire:transaction=off

-- Your Circle candidate discovery scans the bounded seven-day signal window for
-- many direct and first-degree actor hashes, then groups the covered rows by
-- canonical story. wire_signal_events is partitioned, so build each leaf index
-- concurrently before attaching it to the parent index. New daily partitions
-- inherit the completed parent index automatically.

SET lock_timeout = '5s';
SET statement_timeout = '30min';

-- Keep constant defaults for the rolling interval between Database Migrator and
-- the worker revision that writes exact provenance. Existing rows retain their
-- signal kind as the best available action and derive the AT URI collection
-- where the source is a repository record.
ALTER TABLE public.wire_signal_events
  ADD COLUMN IF NOT EXISTS source_collection TEXT DEFAULT 'unknown';
ALTER TABLE public.wire_signal_events
  ADD COLUMN IF NOT EXISTS source_action TEXT DEFAULT 'unknown';

UPDATE public.wire_signal_events
SET source_collection = CASE
      WHEN source_collection <> 'unknown' THEN source_collection
      WHEN source_uri ~ '^at://[^/]+/[^/]+' THEN split_part(source_uri, '/', 4)
      ELSE source_collection
    END,
    source_action = CASE
      WHEN source_action = 'unknown' THEN signal_kind
      ELSE source_action
    END
WHERE source_collection = 'unknown'
   OR source_action = 'unknown';

ALTER TABLE public.wire_signal_events
  ALTER COLUMN source_collection SET DEFAULT 'unknown',
  ALTER COLUMN source_collection SET NOT NULL,
  ALTER COLUMN source_action SET DEFAULT 'unknown',
  ALTER COLUMN source_action SET NOT NULL;

COMMENT ON COLUMN public.wire_signal_events.source_collection IS
  'ATProto source collection when known; unknown preserves rolling-writer compatibility.';
COMMENT ON COLUMN public.wire_signal_events.source_action IS
  'Collection-specific source action; legacy rows retain signal_kind as the best-known action.';

-- Preserve the exact v10 baseline while v11 evaluates the newly ingested
-- external records. Inclusive columns keep their existing names; these
-- baseline columns exclude current Margin and Semble collections.
ALTER TABLE public.wire_signal_rollups
  ADD COLUMN IF NOT EXISTS baseline_last_signal_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS baseline_distinct_actors_1h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_distinct_actors_24h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_distinct_actors_7d INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_signals_1h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_signals_24h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_signals_7d INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_recommendations_24h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_shares_1h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_shares_24h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_distinct_likers_24h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_likes_1h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baseline_likes_24h INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.wire_signal_rollups.baseline_distinct_actors_7d IS
  'Distinct seven-day actors excluding current Margin and Semble collections for wire-v10.';

CREATE INDEX IF NOT EXISTS wire_signal_events_actor_time_idx
  ON ONLY public.wire_signal_events
    (actor_key_hash, occurred_at DESC, canonical_key)
  INCLUDE (source_uri, signal_kind, source_collection, source_action);

-- Recover cleanly if a previous autocommitted run left an invalid leaf index.
SELECT format('DROP INDEX CONCURRENTLY IF EXISTS %s', child_index.oid::regclass)
FROM pg_inherits partition_inheritance
JOIN pg_class partition_relation
  ON partition_relation.oid = partition_inheritance.inhrelid
JOIN pg_class child_index
  ON child_index.relnamespace = partition_relation.relnamespace
 AND child_index.relname = partition_relation.relname || '_actor_time_idx'
JOIN pg_index child_index_state
  ON child_index_state.indexrelid = child_index.oid
WHERE partition_inheritance.inhparent = 'public.wire_signal_events'::regclass
  AND NOT child_index_state.indisvalid
  AND NOT EXISTS (
    SELECT 1
    FROM pg_inherits index_attachment
    WHERE index_attachment.inhparent =
      'public.wire_signal_events_actor_time_idx'::regclass
      AND index_attachment.inhrelid = child_index.oid
  )
\gexec

SELECT format(
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON %s '
  || '(actor_key_hash, occurred_at DESC, canonical_key) '
  || 'INCLUDE (source_uri, signal_kind, source_collection, source_action)',
  partition_relation.relname || '_actor_time_idx',
  partition_relation.oid::regclass
)
FROM pg_inherits partition_inheritance
JOIN pg_class partition_relation
  ON partition_relation.oid = partition_inheritance.inhrelid
WHERE partition_inheritance.inhparent = 'public.wire_signal_events'::regclass
  AND NOT EXISTS (
    SELECT 1
    FROM pg_inherits index_attachment
    JOIN pg_index attached_index_state
      ON attached_index_state.indexrelid = index_attachment.inhrelid
    WHERE index_attachment.inhparent =
      'public.wire_signal_events_actor_time_idx'::regclass
      AND attached_index_state.indrelid = partition_relation.oid
  )
ORDER BY partition_relation.oid
\gexec

SELECT format(
  'ALTER INDEX public.wire_signal_events_actor_time_idx ATTACH PARTITION %s',
  child_index.oid::regclass
)
FROM pg_inherits partition_inheritance
JOIN pg_class partition_relation
  ON partition_relation.oid = partition_inheritance.inhrelid
JOIN pg_class child_index
  ON child_index.relnamespace = partition_relation.relnamespace
 AND child_index.relname = partition_relation.relname || '_actor_time_idx'
JOIN pg_index child_index_state
  ON child_index_state.indexrelid = child_index.oid
WHERE partition_inheritance.inhparent = 'public.wire_signal_events'::regclass
  AND child_index_state.indisvalid
  AND NOT EXISTS (
    SELECT 1
    FROM pg_inherits index_attachment
    JOIN pg_index attached_index_state
      ON attached_index_state.indexrelid = index_attachment.inhrelid
    WHERE index_attachment.inhparent =
      'public.wire_signal_events_actor_time_idx'::regclass
      AND attached_index_state.indrelid = partition_relation.oid
  )
ORDER BY partition_relation.oid
\gexec

COMMENT ON INDEX public.wire_signal_events_actor_time_idx IS
  'Covers seven-day Your Circle candidates selected by actor_key_hash = ANY($1) '
  'and occurred_at >= $2: canonical_key, signal_kind, actor_key_hash, source_uri, occurred_at, '
  'source_collection, source_action.';

RESET statement_timeout;
RESET lock_timeout;
