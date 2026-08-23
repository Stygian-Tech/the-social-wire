-- The Wire inbox and ranking inputs are rebuildable hot-path projections. This
-- migration is an offline operation: pause every Wire ingester, drain worker,
-- and rank worker before applying it. The five-second lock timeout makes an
-- accidental live rollout fail closed instead of waiting behind active work.
-- Durable items, aliases, rank generations/items, feed state, and edition
-- tables deliberately remain LOGGED so the last committed edition survives a
-- PostgreSQL crash while the hot path replays.

SET LOCAL lock_timeout = '5s';

LOCK TABLE wire_ingestion_inbox IN ACCESS EXCLUSIVE MODE;

CREATE TEMP TABLE wire_inbox_relation_metadata ON COMMIT DROP AS
SELECT pg_get_userbyid(relation.relowner) AS owner_name
FROM pg_class relation
WHERE relation.oid = 'wire_ingestion_inbox'::REGCLASS;

CREATE TEMP TABLE wire_inbox_relation_grants ON COMMIT DROP AS
SELECT
  CASE WHEN grant_row.grantee = 0 THEN 'PUBLIC'
       ELSE pg_get_userbyid(grant_row.grantee) END AS grantee_name,
  grant_row.privilege_type,
  grant_row.is_grantable
FROM pg_class relation
CROSS JOIN LATERAL aclexplode(
  COALESCE(relation.relacl, acldefault('r', relation.relowner))
) grant_row
WHERE relation.oid = 'wire_ingestion_inbox'::REGCLASS;

-- Read the large logged heap once. The compact replacement and its exact
-- recovery floor both consume this bounded temporary snapshot.
CREATE TEMP TABLE wire_actionable_inbox ON COMMIT DROP AS
SELECT *
FROM wire_ingestion_inbox
WHERE status IN ('pending', 'leased', 'retry');

-- A logged hourly cursor journal gives crash recovery a provider-authored
-- cursor. Never derive a Jetstream cursor by doing arithmetic on its value.
CREATE TABLE IF NOT EXISTS wire_ingestion_recovery_anchors (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  anchor_bucket TIMESTAMPTZ NOT NULL,
  checkpoint_seq BIGINT NOT NULL CHECK (checkpoint_seq >= 0),
  checkpoint_event_time TIMESTAMPTZ NOT NULL,
  captured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (environment, source_generation, anchor_bucket)
);

CREATE INDEX IF NOT EXISTS wire_ingestion_recovery_anchors_cursor_idx
  ON wire_ingestion_recovery_anchors
    (environment, source_generation, checkpoint_seq);

-- Preserve a deterministic replay floor for every actionable generation before
-- terminal rows are discarded and the inbox is converted.
INSERT INTO wire_ingestion_recovery_anchors
  (environment, source_generation, anchor_bucket, checkpoint_seq,
   checkpoint_event_time, captured_at)
SELECT DISTINCT ON (environment, source_generation)
  environment,
  source_generation,
  date_trunc('hour', NOW()),
  seq,
  event_time,
  NOW()
FROM wire_actionable_inbox
ORDER BY environment, source_generation, seq
ON CONFLICT (environment, source_generation, anchor_bucket) DO UPDATE
SET checkpoint_event_time = CASE
      WHEN EXCLUDED.checkpoint_seq < wire_ingestion_recovery_anchors.checkpoint_seq
      THEN EXCLUDED.checkpoint_event_time
      ELSE wire_ingestion_recovery_anchors.checkpoint_event_time
    END,
    captured_at = CASE
      WHEN EXCLUDED.checkpoint_seq < wire_ingestion_recovery_anchors.checkpoint_seq
      THEN EXCLUDED.captured_at
      ELSE wire_ingestion_recovery_anchors.captured_at
    END,
    checkpoint_seq = LEAST(
      wire_ingestion_recovery_anchors.checkpoint_seq,
      EXCLUDED.checkpoint_seq
    );

-- A generation with no actionable rows still needs a provider-authored anchor
-- so a later crash is distinguishable from first bootstrap.
INSERT INTO wire_ingestion_recovery_anchors
  (environment, source_generation, anchor_bucket, checkpoint_seq,
   checkpoint_event_time, captured_at)
SELECT
  checkpoint.environment,
  checkpoint.source_generation,
  date_trunc('hour', NOW()),
  checkpoint.last_staged_seq,
  checkpoint.last_staged_event_at,
  NOW()
FROM appview_jetstream_checkpoints checkpoint
WHERE checkpoint.last_staged_seq IS NOT NULL
  AND checkpoint.last_staged_event_at IS NOT NULL
  AND checkpoint.source_generation LIKE 'wire-%'
ON CONFLICT (environment, source_generation, anchor_bucket) DO UPDATE
SET checkpoint_event_time = CASE
      WHEN EXCLUDED.checkpoint_seq < wire_ingestion_recovery_anchors.checkpoint_seq
      THEN EXCLUDED.checkpoint_event_time
      ELSE wire_ingestion_recovery_anchors.checkpoint_event_time
    END,
    captured_at = CASE
      WHEN EXCLUDED.checkpoint_seq < wire_ingestion_recovery_anchors.checkpoint_seq
      THEN EXCLUDED.captured_at
      ELSE wire_ingestion_recovery_anchors.captured_at
    END,
    checkpoint_seq = LEAST(
      wire_ingestion_recovery_anchors.checkpoint_seq,
      EXCLUDED.checkpoint_seq
    );

-- Clean shutdowns preserve this UNLOGGED marker. PostgreSQL crash recovery
-- truncates it together with the inbox, allowing the fenced ingester to detect
-- loss and rewind only its own immutable source generation.
CREATE UNLOGGED TABLE IF NOT EXISTS wire_ingestion_inbox_epochs (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  initialized_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (environment, source_generation)
);

INSERT INTO wire_ingestion_inbox_epochs (environment, source_generation)
SELECT environment, source_generation
FROM wire_ingestion_recovery_anchors
ON CONFLICT (environment, source_generation) DO NOTHING;

-- Compact-and-swap avoids rewriting the 8+ GiB logged heap and carrying millions
-- of terminal rows into the new relation. LIKE intentionally excludes indexes;
-- canonical indexes are recreated only after the old heap has been dropped.
CREATE UNLOGGED TABLE wire_ingestion_inbox_unlogged
  (LIKE wire_ingestion_inbox
    INCLUDING DEFAULTS
    INCLUDING CONSTRAINTS
    INCLUDING STORAGE
    INCLUDING COMMENTS);

INSERT INTO wire_ingestion_inbox_unlogged
SELECT *
FROM wire_actionable_inbox;

-- A stopped worker can leave valid leases behind. Return them to the retry lane
-- without changing attempts or repository ordering.
UPDATE wire_ingestion_inbox_unlogged
SET status = 'retry',
    next_attempt_at = LEAST(next_attempt_at, NOW()),
    lease_owner = NULL,
    lease_token = NULL,
    lease_expires_at = NULL,
    updated_at = NOW()
WHERE status = 'leased';

DROP TABLE wire_ingestion_inbox;
ALTER TABLE wire_ingestion_inbox_unlogged RENAME TO wire_ingestion_inbox;

DO $$
DECLARE
  original_owner TEXT;
  grant_row RECORD;
BEGIN
  SELECT owner_name INTO STRICT original_owner
  FROM wire_inbox_relation_metadata;
  EXECUTE format('ALTER TABLE wire_ingestion_inbox OWNER TO %I', original_owner);

  FOR grant_row IN SELECT * FROM wire_inbox_relation_grants LOOP
    EXECUTE format(
      'GRANT %s ON TABLE wire_ingestion_inbox TO %s%s',
      grant_row.privilege_type,
      CASE WHEN grant_row.grantee_name = 'PUBLIC' THEN 'PUBLIC'
           ELSE format('%I', grant_row.grantee_name) END,
      CASE WHEN grant_row.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
    );
  END LOOP;
END
$$;

ALTER TABLE wire_ingestion_inbox
  ADD CONSTRAINT wire_ingestion_inbox_pkey
  PRIMARY KEY (environment, source_generation, seq);

CREATE INDEX wire_ingestion_inbox_pending_retry_ready_idx
  ON wire_ingestion_inbox (next_attempt_at, seq)
  WHERE status IN ('pending', 'retry');
CREATE INDEX wire_ingestion_inbox_expired_lease_idx
  ON wire_ingestion_inbox (lease_expires_at, seq)
  WHERE status = 'leased';
CREATE INDEX wire_ingestion_inbox_repo_fifo_idx
  ON wire_ingestion_inbox (environment, source_generation, repo_did, seq)
  WHERE status IN ('pending', 'leased', 'retry');
CREATE INDEX wire_ingestion_inbox_expires_idx
  ON wire_ingestion_inbox (expires_at, environment, source_generation, seq);
CREATE INDEX wire_ingestion_inbox_dead_letter_idx
  ON wire_ingestion_inbox (environment, dead_lettered_at DESC)
  WHERE status = 'dead_letter';

UPDATE wire_ingestion_admission admission
SET retained_rows = (
      SELECT COUNT(*)
      FROM wire_ingestion_inbox inbox
      WHERE inbox.environment = admission.environment
    ),
    updated_at = NOW();

-- These tables are bounded inputs rebuilt from the replayable public source.
-- They are never part of the committed serving snapshot.
ALTER TABLE wire_active_actors SET UNLOGGED;
ALTER TABLE wire_follow_edges SET UNLOGGED;
ALTER TABLE wire_actor_communities SET UNLOGGED;
ALTER TABLE wire_signal_rollups SET UNLOGGED;
ALTER TABLE wire_item_mentions SET UNLOGGED;
ALTER TABLE wire_article_feedback SET UNLOGGED;

-- SET UNLOGGED is not supported on a partitioned parent, so convert every leaf
-- and make the lazy partition factory create future leaves as UNLOGGED.
DO $$
DECLARE
  signal_partition REGCLASS;
BEGIN
  FOR signal_partition IN
    SELECT inheritance.inhrelid::REGCLASS
    FROM pg_inherits inheritance
    WHERE inheritance.inhparent = 'wire_signal_events'::REGCLASS
  LOOP
    EXECUTE format('ALTER TABLE %s SET UNLOGGED', signal_partition);
  END LOOP;
END
$$;

ALTER SEQUENCE IF EXISTS wire_signal_events_id_seq SET UNLOGGED;
ALTER SEQUENCE IF EXISTS wire_signal_events_id_seq CACHE 1000;

CREATE OR REPLACE FUNCTION ensure_wire_signal_event_partition(event_day DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  partition_name TEXT := 'wire_signal_events_' || to_char(event_day, 'YYYYMMDD');
  range_start TIMESTAMPTZ := event_day::TIMESTAMP AT TIME ZONE 'UTC';
  range_end TIMESTAMPTZ := (event_day + 1)::TIMESTAMP AT TIME ZONE 'UTC';
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('wire_signal_events'), hashtext(event_day::TEXT));
  IF to_regclass(partition_name) IS NULL THEN
    EXECUTE format(
      'CREATE UNLOGGED TABLE %I PARTITION OF wire_signal_events FOR VALUES FROM (%L) TO (%L)',
      partition_name,
      range_start,
      range_end
    );
  END IF;
END;
$$;

ANALYZE wire_ingestion_inbox;

DO $$
DECLARE
  relation_name TEXT;
  relation_persistence "char";
  original_owner TEXT;
  current_owner TEXT;
  expected_index TEXT;
  signal_partition REGCLASS;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'wire_ingestion_inbox',
    'wire_ingestion_inbox_epochs',
    'wire_active_actors',
    'wire_follow_edges',
    'wire_actor_communities',
    'wire_signal_rollups',
    'wire_item_mentions',
    'wire_article_feedback'
  ] LOOP
    SELECT relpersistence INTO relation_persistence
    FROM pg_class
    WHERE oid = relation_name::REGCLASS;
    IF relation_persistence IS DISTINCT FROM 'u' THEN
      RAISE EXCEPTION '% must be UNLOGGED, got %', relation_name, relation_persistence;
    END IF;
  END LOOP;

  FOREACH relation_name IN ARRAY ARRAY[
    'wire_items',
    'wire_item_aliases',
    'wire_ingestion_recovery_anchors',
    'wire_rank_generations',
    'wire_ranked_items',
    'wire_feed_state',
    'wire_edition_generations',
    'wire_edition_modules',
    'wire_edition_module_items',
    'wire_edition_talked_accounts'
  ] LOOP
    SELECT relpersistence INTO relation_persistence
    FROM pg_class
    WHERE oid = relation_name::REGCLASS;
    IF relation_persistence IS DISTINCT FROM 'p' THEN
      RAISE EXCEPTION '% must remain LOGGED, got %', relation_name, relation_persistence;
    END IF;
  END LOOP;

  SELECT owner_name INTO STRICT original_owner
  FROM wire_inbox_relation_metadata;
  SELECT pg_get_userbyid(relowner) INTO STRICT current_owner
  FROM pg_class
  WHERE oid = 'wire_ingestion_inbox'::REGCLASS;
  IF current_owner IS DISTINCT FROM original_owner THEN
    RAISE EXCEPTION 'Wire inbox owner changed from % to %', original_owner, current_owner;
  END IF;

  FOREACH expected_index IN ARRAY ARRAY[
    'wire_ingestion_inbox_pkey',
    'wire_ingestion_inbox_pending_retry_ready_idx',
    'wire_ingestion_inbox_expired_lease_idx',
    'wire_ingestion_inbox_repo_fifo_idx',
    'wire_ingestion_inbox_expires_idx',
    'wire_ingestion_inbox_dead_letter_idx'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_index
      WHERE indexrelid = expected_index::REGCLASS AND indisvalid
    ) THEN
      RAISE EXCEPTION 'Wire inbox index % is missing or invalid', expected_index;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM wire_ingestion_inbox WHERE status = 'leased') THEN
    RAISE EXCEPTION 'Wire inbox compact-and-swap retained a lease';
  END IF;
  IF EXISTS (
    SELECT 1 FROM wire_ingestion_inbox WHERE status IN ('applied', 'dead_letter')
  ) THEN
    RAISE EXCEPTION 'Wire inbox compact-and-swap retained terminal rows';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM wire_ingestion_admission admission
    WHERE admission.retained_rows <> (
      SELECT COUNT(*) FROM wire_ingestion_inbox inbox
      WHERE inbox.environment = admission.environment
    )
  ) THEN
    RAISE EXCEPTION 'Wire inbox admission counter does not match compacted rows';
  END IF;

  FOR signal_partition IN
    SELECT inheritance.inhrelid::REGCLASS
    FROM pg_inherits inheritance
    WHERE inheritance.inhparent = 'wire_signal_events'::REGCLASS
  LOOP
    SELECT relpersistence INTO relation_persistence
    FROM pg_class WHERE oid = signal_partition;
    IF relation_persistence IS DISTINCT FROM 'u' THEN
      RAISE EXCEPTION 'Wire signal partition % must be UNLOGGED', signal_partition;
    END IF;
  END LOOP;

  SELECT relpersistence INTO relation_persistence
  FROM pg_class WHERE oid = 'wire_signal_events_id_seq'::REGCLASS;
  IF relation_persistence IS DISTINCT FROM 'u' THEN
    RAISE EXCEPTION 'Wire signal identity sequence must be UNLOGGED';
  END IF;
END
$$;

COMMENT ON TABLE wire_ingestion_inbox IS
  'UNLOGGED rebuildable Wire staging queue. A PostgreSQL crash truncates it; fenced ingest startup detects the missing generation epoch and replays from a logged provider-authored recovery anchor.';
COMMENT ON TABLE wire_ingestion_recovery_anchors IS
  'Logged hourly provider-authored cursors used to recover the UNLOGGED Wire inbox without assuming cursor encoding.';
COMMENT ON TABLE wire_ingestion_inbox_epochs IS
  'UNLOGGED crash sentinel, scoped by environment and immutable source generation.';
