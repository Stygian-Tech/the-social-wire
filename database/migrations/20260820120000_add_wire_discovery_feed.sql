-- Postgres is the durable authority for The Wire. Every table below is rebuildable
-- from public content and privacy-safe aggregate signals; Redis may mirror committed
-- generations, but is never the source of truth.

CREATE TABLE IF NOT EXISTS wire_items (
  canonical_key TEXT PRIMARY KEY,
  canonical_url TEXT NOT NULL UNIQUE,
  representative_uri TEXT,
  publication_id TEXT,
  author_key TEXT,
  source_domain TEXT NOT NULL,
  source_name TEXT NOT NULL,
  author_name TEXT,
  title TEXT NOT NULL,
  summary TEXT,
  thumbnail_url TEXT,
  language_code TEXT NOT NULL DEFAULT 'und',
  topic_keys JSONB NOT NULL DEFAULT '[]'::jsonb,
  presentation_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
  provenance JSONB NOT NULL DEFAULT '[]'::jsonb,
  published_at TIMESTAMPTZ,
  first_seen_at TIMESTAMPTZ NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL,
  last_signal_at TIMESTAMPTZ,
  source_confidence DOUBLE PRECISION NOT NULL DEFAULT 0.5,
  eligible BOOLEAN NOT NULL DEFAULT TRUE,
  expires_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT wire_items_canonical_key_length CHECK (char_length(canonical_key) BETWEEN 1 AND 160),
  CONSTRAINT wire_items_source_confidence_range CHECK (
    source_confidence BETWEEN 0 AND 1 AND source_confidence::text <> 'NaN'
  ),
  CONSTRAINT wire_items_topic_keys_array CHECK (jsonb_typeof(topic_keys) = 'array'),
  CONSTRAINT wire_items_presentation_object CHECK (jsonb_typeof(presentation_snapshot) = 'object'),
  CONSTRAINT wire_items_provenance_array CHECK (jsonb_typeof(provenance) = 'array')
);

CREATE INDEX IF NOT EXISTS wire_items_eligible_signal_idx
  ON wire_items (language_code, last_signal_at DESC, canonical_key)
  WHERE eligible = TRUE;
CREATE INDEX IF NOT EXISTS wire_items_expires_idx
  ON wire_items (expires_at, canonical_key);
CREATE INDEX IF NOT EXISTS wire_items_source_domain_idx
  ON wire_items (source_domain, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS wire_item_aliases (
  alias_key TEXT PRIMARY KEY,
  canonical_key TEXT NOT NULL REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  alias_type TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT wire_item_aliases_type CHECK (alias_type IN ('at_uri', 'url', 'redirect', 'syndication'))
);

CREATE INDEX IF NOT EXISTS wire_item_aliases_canonical_idx
  ON wire_item_aliases (canonical_key);
CREATE INDEX IF NOT EXISTS wire_item_aliases_expires_idx
  ON wire_item_aliases (expires_at, alias_key);

CREATE TABLE IF NOT EXISTS wire_ingestion_inbox (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  seq BIGINT NOT NULL,
  source_host TEXT NOT NULL,
  cursor_kind TEXT NOT NULL,
  event_kind TEXT NOT NULL,
  repo_did TEXT NOT NULL,
  collection TEXT,
  operation TEXT,
  repo_rev TEXT,
  record_key TEXT,
  record_cid TEXT,
  payload JSONB NOT NULL,
  event_time TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  staged_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lease_owner TEXT,
  lease_token TEXT,
  lease_expires_at TIMESTAMPTZ,
  failure_category TEXT,
  failure_reason TEXT,
  applied_at TIMESTAMPTZ,
  dead_lettered_at TIMESTAMPTZ,
  reconciled_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '14 days'),
  PRIMARY KEY (environment, source_generation, seq),
  CONSTRAINT wire_ingestion_inbox_payload_object CHECK (jsonb_typeof(payload) = 'object'),
  CONSTRAINT wire_ingestion_inbox_status CHECK (status IN ('pending', 'leased', 'retry', 'applied', 'dead_letter')),
  CONSTRAINT wire_ingestion_inbox_sequence_nonnegative CHECK (seq >= 0),
  CONSTRAINT wire_ingestion_inbox_attempts_nonnegative CHECK (attempt_count >= 0),
  CONSTRAINT wire_ingestion_inbox_lease_complete CHECK (
    (status = 'leased' AND lease_owner IS NOT NULL AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR status != 'leased'
  ),
  CONSTRAINT wire_ingestion_inbox_applied_timestamp CHECK (status != 'applied' OR applied_at IS NOT NULL),
  CONSTRAINT wire_ingestion_inbox_dead_timestamp CHECK (status != 'dead_letter' OR dead_lettered_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS wire_ingestion_inbox_claim_idx
  ON wire_ingestion_inbox (environment, source_generation, status, next_attempt_at, seq)
  WHERE status IN ('pending', 'leased', 'retry');
CREATE INDEX IF NOT EXISTS wire_ingestion_inbox_repo_fifo_idx
  ON wire_ingestion_inbox (environment, source_generation, repo_did, seq)
  WHERE status IN ('pending', 'leased', 'retry');
CREATE INDEX IF NOT EXISTS wire_ingestion_inbox_expires_idx
  ON wire_ingestion_inbox (expires_at, environment, source_generation, seq);
CREATE INDEX IF NOT EXISTS wire_ingestion_inbox_dead_letter_idx
  ON wire_ingestion_inbox (environment, dead_lettered_at DESC)
  WHERE status = 'dead_letter';

-- All actor identifiers are keyed hashes. These bounded, expiring graph tables
-- support breadth/community aggregates without making the serving API personal.
CREATE TABLE IF NOT EXISTS wire_active_actors (
  actor_key_hash TEXT PRIMARY KEY,
  first_active_at TIMESTAMPTZ NOT NULL,
  last_active_at TIMESTAMPTZ NOT NULL,
  public_signal_count INTEGER NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT wire_active_actors_hash_length CHECK (char_length(actor_key_hash) BETWEEN 16 AND 160),
  CONSTRAINT wire_active_actors_count_nonnegative CHECK (public_signal_count >= 0)
);

CREATE INDEX IF NOT EXISTS wire_active_actors_activity_idx
  ON wire_active_actors (last_active_at DESC, actor_key_hash);
CREATE INDEX IF NOT EXISTS wire_active_actors_expires_idx
  ON wire_active_actors (expires_at, actor_key_hash);

CREATE TABLE IF NOT EXISTS wire_follow_edges (
  source_uri TEXT NOT NULL UNIQUE,
  follower_key_hash TEXT NOT NULL,
  followee_key_hash TEXT NOT NULL,
  observed_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (follower_key_hash, followee_key_hash),
  CONSTRAINT wire_follow_edges_not_self CHECK (follower_key_hash <> followee_key_hash)
);

CREATE INDEX IF NOT EXISTS wire_follow_edges_followee_idx
  ON wire_follow_edges (followee_key_hash, follower_key_hash);
CREATE INDEX IF NOT EXISTS wire_follow_edges_expires_idx
  ON wire_follow_edges (expires_at, follower_key_hash, followee_key_hash);

CREATE TABLE IF NOT EXISTS wire_actor_communities (
  actor_key_hash TEXT PRIMARY KEY,
  community_key_hash TEXT NOT NULL,
  algorithm_version TEXT NOT NULL,
  assigned_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS wire_actor_communities_lookup_idx
  ON wire_actor_communities (community_key_hash, actor_key_hash);
CREATE INDEX IF NOT EXISTS wire_actor_communities_expires_idx
  ON wire_actor_communities (expires_at, actor_key_hash);

CREATE TABLE IF NOT EXISTS wire_labels (
  canonical_key TEXT NOT NULL REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  label_key TEXT NOT NULL,
  label_value TEXT NOT NULL,
  source TEXT NOT NULL,
  confidence DOUBLE PRECISION NOT NULL DEFAULT 1,
  applied_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (canonical_key, label_key, source),
  CONSTRAINT wire_labels_confidence_range CHECK (confidence BETWEEN 0 AND 1 AND confidence::text <> 'NaN')
);

CREATE INDEX IF NOT EXISTS wire_labels_filter_idx
  ON wire_labels (label_key, label_value, applied_at DESC, canonical_key);
CREATE INDEX IF NOT EXISTS wire_labels_expires_idx
  ON wire_labels (expires_at, canonical_key);

-- A committed generation may activate only after every configured baseline
-- labeler has completed a fresh, bounded queryLabels snapshot. This state is
-- durable so readiness and operations can distinguish an empty label result
-- from a labeler outage.
CREATE TABLE IF NOT EXISTS wire_label_refresh_state (
  source_did TEXT PRIMARY KEY,
  endpoint_host TEXT NOT NULL,
  last_attempted_at TIMESTAMPTZ NOT NULL,
  last_successful_at TIMESTAMPTZ NOT NULL,
  target_count INTEGER NOT NULL,
  label_count INTEGER NOT NULL,
  is_current BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT wire_label_refresh_counts_nonnegative CHECK (target_count >= 0 AND label_count >= 0)
);

CREATE INDEX IF NOT EXISTS wire_label_refresh_state_freshness_idx
  ON wire_label_refresh_state (last_successful_at, source_did)
  WHERE is_current = TRUE;

CREATE TABLE IF NOT EXISTS wire_signal_events (
  id BIGINT GENERATED BY DEFAULT AS IDENTITY,
  event_key TEXT NOT NULL,
  canonical_key TEXT NOT NULL REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  signal_kind TEXT NOT NULL,
  actor_key_hash TEXT NOT NULL,
  community_key_hash TEXT,
  source_uri TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  CONSTRAINT wire_signal_events_kind CHECK (
    signal_kind IN ('recommendation', 'share', 'quote', 'reply', 'like', 'repost', 'publication')
  ),
  CONSTRAINT wire_signal_events_actor_hash_length CHECK (char_length(actor_key_hash) BETWEEN 16 AND 160),
  PRIMARY KEY (occurred_at, id),
  UNIQUE (occurred_at, event_key)
) PARTITION BY RANGE (occurred_at);

-- The worker calls this before inserting an event. Creating partitions lazily keeps
-- the migration provider-neutral while preserving bounded archive replay. The
-- transaction-scoped advisory lock prevents two workers racing at midnight.
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
      'CREATE TABLE %I PARTITION OF wire_signal_events FOR VALUES FROM (%L) TO (%L)',
      partition_name,
      range_start,
      range_end
    );
  END IF;
END;
$$;

-- Ensure a seven-day replay can begin immediately after migration. Future days are
-- created by ensure_wire_signal_event_partition as events arrive.
DO $$
DECLARE
  offset_days INTEGER;
BEGIN
  FOR offset_days IN -7..1 LOOP
    PERFORM ensure_wire_signal_event_partition(
      ((CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::DATE + offset_days)::DATE
    );
  END LOOP;
END;
$$;

CREATE INDEX IF NOT EXISTS wire_signal_events_item_time_idx
  ON wire_signal_events (canonical_key, occurred_at DESC);
CREATE INDEX IF NOT EXISTS wire_signal_events_kind_time_idx
  ON wire_signal_events (signal_kind, occurred_at DESC, canonical_key);
CREATE INDEX IF NOT EXISTS wire_signal_events_source_uri_idx
  ON wire_signal_events (source_uri, occurred_at DESC);
CREATE INDEX IF NOT EXISTS wire_signal_events_expires_idx
  ON wire_signal_events (expires_at, occurred_at, id);

-- This table is the worker-maintained, privacy-safe ranking input. It deliberately
-- stores counts only: raw actor/community identifiers never reach the serving path.
CREATE TABLE IF NOT EXISTS wire_signal_rollups (
  canonical_key TEXT PRIMARY KEY REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  distinct_actors_1h INTEGER NOT NULL DEFAULT 0,
  distinct_actors_24h INTEGER NOT NULL DEFAULT 0,
  distinct_actors_7d INTEGER NOT NULL DEFAULT 0,
  signals_1h INTEGER NOT NULL DEFAULT 0,
  signals_24h INTEGER NOT NULL DEFAULT 0,
  signals_7d INTEGER NOT NULL DEFAULT 0,
  communities_24h INTEGER NOT NULL DEFAULT 0,
  primary_community_key_hash TEXT,
  recommendations_24h INTEGER NOT NULL DEFAULT 0,
  shares_1h INTEGER NOT NULL DEFAULT 0,
  shares_24h INTEGER NOT NULL DEFAULT 0,
  distinct_likers_24h INTEGER NOT NULL DEFAULT 0,
  likes_1h INTEGER NOT NULL DEFAULT 0,
  likes_24h INTEGER NOT NULL DEFAULT 0,
  distinct_reposters_24h INTEGER NOT NULL DEFAULT 0,
  reposts_1h INTEGER NOT NULL DEFAULT 0,
  reposts_24h INTEGER NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT wire_signal_rollups_nonnegative CHECK (
    distinct_actors_1h >= 0 AND distinct_actors_24h >= 0 AND distinct_actors_7d >= 0
    AND signals_1h >= 0 AND signals_24h >= 0 AND signals_7d >= 0
    AND communities_24h >= 0 AND recommendations_24h >= 0
    AND shares_1h >= 0 AND shares_24h >= 0
    AND distinct_likers_24h >= 0 AND likes_1h >= 0 AND likes_24h >= 0
    AND distinct_reposters_24h >= 0 AND reposts_1h >= 0 AND reposts_24h >= 0
  )
);

CREATE INDEX IF NOT EXISTS wire_signal_rollups_rank_idx
  ON wire_signal_rollups (distinct_actors_24h DESC, signals_1h DESC, canonical_key);
CREATE INDEX IF NOT EXISTS wire_signal_rollups_updated_idx
  ON wire_signal_rollups (updated_at, canonical_key);

CREATE TABLE IF NOT EXISTS wire_rank_generations (
  generation_id UUID PRIMARY KEY,
  feed_key TEXT NOT NULL DEFAULT 'wire',
  language_bucket TEXT NOT NULL DEFAULT 'und',
  status TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT FALSE,
  config_version TEXT NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL,
  committed_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL,
  candidate_count INTEGER NOT NULL DEFAULT 0,
  ranked_count INTEGER NOT NULL DEFAULT 0,
  diagnostics JSONB NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT wire_rank_generations_status CHECK (
    status IN ('building', 'shadow', 'committed', 'superseded', 'failed')
  ),
  CONSTRAINT wire_rank_generations_counts_nonnegative CHECK (candidate_count >= 0 AND ranked_count >= 0),
  CONSTRAINT wire_rank_generations_diagnostics_object CHECK (jsonb_typeof(diagnostics) = 'object'),
  CONSTRAINT wire_rank_generations_active_committed CHECK (NOT is_active OR status = 'committed')
);

CREATE UNIQUE INDEX IF NOT EXISTS wire_rank_generations_one_active_idx
  ON wire_rank_generations (feed_key, language_bucket)
  WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS wire_rank_generations_history_idx
  ON wire_rank_generations (feed_key, language_bucket, generated_at DESC);
CREATE INDEX IF NOT EXISTS wire_rank_generations_expires_idx
  ON wire_rank_generations (expires_at, generation_id);

CREATE TABLE IF NOT EXISTS wire_ranked_items (
  generation_id UUID NOT NULL REFERENCES wire_rank_generations(generation_id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  canonical_key TEXT NOT NULL REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  score DOUBLE PRECISION NOT NULL,
  reason_codes JSONB NOT NULL DEFAULT '[]'::jsonb,
  diversity_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (generation_id, position),
  UNIQUE (generation_id, canonical_key),
  CONSTRAINT wire_ranked_items_position_nonnegative CHECK (position >= 0),
  CONSTRAINT wire_ranked_items_score_finite CHECK (
    score NOT IN ('Infinity'::float8, '-Infinity'::float8) AND score::text <> 'NaN'
  ),
  CONSTRAINT wire_ranked_items_reasons_array CHECK (jsonb_typeof(reason_codes) = 'array'),
  CONSTRAINT wire_ranked_items_diversity_object CHECK (jsonb_typeof(diversity_metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS wire_ranked_items_lookup_idx
  ON wire_ranked_items (generation_id, canonical_key);

-- The serving tier reads this single row to obtain a stable, generation-bound page.
-- Updating the pointer and inserting ranked rows happen in one transaction.
CREATE TABLE IF NOT EXISTS wire_feed_state (
  feed_key TEXT NOT NULL,
  language_bucket TEXT NOT NULL DEFAULT 'und',
  active_generation_id UUID REFERENCES wire_rank_generations(generation_id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (feed_key, language_bucket)
);

COMMENT ON TABLE wire_signal_events IS
  'Short-retention public discovery signals. actor_key_hash and community_key_hash must be keyed hashes, never raw DIDs.';
COMMENT ON TABLE wire_signal_rollups IS
  'Privacy-safe aggregate ranking input; rebuildable from short-retention signal events.';
COMMENT ON TABLE wire_rank_generations IS
  'Durable materialized Wire generations. Redis, when enabled, is a disposable read-through mirror only.';
