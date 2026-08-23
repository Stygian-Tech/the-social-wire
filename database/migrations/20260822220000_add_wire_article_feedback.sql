-- Project public, viewer-authored Wire article assessments into privacy-safe,
-- one-viewer-per-story rows. Raw DIDs never enter this projection or rollups.

CREATE TABLE IF NOT EXISTS wire_article_feedback (
  canonical_key TEXT NOT NULL REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  actor_key_hash TEXT NOT NULL,
  source_uri TEXT NOT NULL UNIQUE,
  feedback_value TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (canonical_key, actor_key_hash),
  CONSTRAINT wire_article_feedback_value CHECK (feedback_value IN ('good', 'not_good')),
  CONSTRAINT wire_article_feedback_actor_hash_length CHECK (
    char_length(actor_key_hash) BETWEEN 16 AND 160
  )
);

CREATE INDEX IF NOT EXISTS wire_article_feedback_expires_idx
  ON wire_article_feedback (expires_at, canonical_key);

ALTER TABLE wire_signal_rollups
  ADD COLUMN IF NOT EXISTS positive_feedback_24h INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS negative_feedback_24h INTEGER NOT NULL DEFAULT 0;

ALTER TABLE wire_signal_rollups
  DROP CONSTRAINT IF EXISTS wire_signal_rollups_nonnegative;
ALTER TABLE wire_signal_rollups
  ADD CONSTRAINT wire_signal_rollups_nonnegative CHECK (
    distinct_actors_1h >= 0 AND distinct_actors_24h >= 0 AND distinct_actors_7d >= 0
    AND signals_1h >= 0 AND signals_24h >= 0 AND signals_7d >= 0
    AND communities_24h >= 0 AND recommendations_24h >= 0
    AND positive_feedback_24h >= 0 AND negative_feedback_24h >= 0
    AND shares_1h >= 0 AND shares_24h >= 0
    AND distinct_likers_24h >= 0 AND likes_1h >= 0 AND likes_24h >= 0
    AND distinct_reposters_24h >= 0 AND reposts_1h >= 0 AND reposts_24h >= 0
  );

COMMENT ON TABLE wire_article_feedback IS
  'Rebuildable, expiring Wire article-quality projection. Viewer DIDs are HMAC-only and rows are never exposed by serving views.';
COMMENT ON COLUMN wire_signal_rollups.positive_feedback_24h IS
  'Private distinct-viewer aggregate; never exposed by the Wire API or Corpus Edge.';
COMMENT ON COLUMN wire_signal_rollups.negative_feedback_24h IS
  'Private distinct-viewer aggregate; never exposed by the Wire API or Corpus Edge.';
