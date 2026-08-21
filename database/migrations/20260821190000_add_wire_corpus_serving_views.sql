-- The Wire Corpus Edge is the only cross-environment presentation boundary. These
-- views expose presentation-safe corpus state without raw signals, actor hashes,
-- scores, ranking diagnostics, label details, or operational counts. Role creation
-- and credentials remain environment-specific operator work.

CREATE SCHEMA IF NOT EXISTS wire_serving;
REVOKE ALL ON SCHEMA wire_serving FROM PUBLIC;

CREATE OR REPLACE VIEW wire_serving.contract AS
SELECT 1::INTEGER AS contract_version;

CREATE OR REPLACE VIEW wire_serving.label_health AS
SELECT
  BOOL_OR(is_current) AS has_current_snapshot,
  MIN(last_successful_at) FILTER (WHERE is_current) AS oldest_successful_at
FROM wire_label_refresh_state;

CREATE OR REPLACE VIEW wire_serving.generations AS
SELECT generation_id, language_bucket, status, generated_at, expires_at
FROM wire_rank_generations
WHERE feed_key = 'wire' AND status IN ('committed', 'superseded');

CREATE OR REPLACE VIEW wire_serving.feed_state AS
SELECT
  state.language_bucket,
  generation.generation_id,
  generation.generated_at,
  generation.expires_at
FROM wire_feed_state AS state
JOIN wire_rank_generations AS generation
  ON generation.generation_id = state.active_generation_id
WHERE state.feed_key = 'wire' AND generation.status = 'committed';

CREATE OR REPLACE VIEW wire_serving.items
WITH (security_barrier = TRUE) AS
SELECT
  item.canonical_key,
  item.canonical_url,
  item.representative_uri,
  item.title,
  item.summary,
  item.published_at,
  item.thumbnail_url,
  item.source_name,
  item.source_domain,
  item.publication_id,
  item.author_name,
  item.provenance,
  item.author_key
FROM wire_items AS item
WHERE item.eligible = TRUE
  AND item.expires_at > CURRENT_TIMESTAMP
  AND NOT EXISTS (
    SELECT 1
    FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key
      AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
  );

CREATE OR REPLACE VIEW wire_serving.ranked_items
WITH (security_barrier = TRUE) AS
SELECT
  ranked.generation_id,
  ranked.position,
  item.canonical_key,
  item.canonical_url,
  item.representative_uri,
  item.title,
  item.summary,
  item.published_at,
  item.thumbnail_url,
  item.source_name,
  item.source_domain,
  item.publication_id,
  item.author_name,
  item.provenance,
  item.author_key,
  ranked.reason_codes
FROM wire_ranked_items AS ranked
JOIN wire_rank_generations AS generation
  ON generation.generation_id = ranked.generation_id
JOIN wire_items AS item
  ON item.canonical_key = ranked.canonical_key
WHERE generation.feed_key = 'wire'
  AND generation.status IN ('committed', 'superseded')
  AND item.eligible = TRUE
  AND item.expires_at > CURRENT_TIMESTAMP
  AND NOT EXISTS (
    SELECT 1
    FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key
      AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
  );

CREATE OR REPLACE VIEW wire_serving.fallback_items
WITH (security_barrier = TRUE) AS
SELECT
  item.canonical_key,
  item.canonical_url,
  item.representative_uri,
  item.title,
  item.summary,
  item.published_at,
  item.thumbnail_url,
  item.source_name,
  item.source_domain,
  item.publication_id,
  item.author_name,
  item.provenance,
  item.author_key,
  item.language_code,
  item.topic_keys,
  item.first_seen_at
FROM wire_items AS item
WHERE item.eligible = TRUE
  AND item.expires_at > CURRENT_TIMESTAMP
  AND item.source_confidence >= 0.75
  AND NOT EXISTS (
    SELECT 1
    FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key
      AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
  );

COMMENT ON SCHEMA wire_serving IS
  'Presentation-safe, read-only contract for the dedicated Production The Wire Corpus Edge.';
COMMENT ON VIEW wire_serving.contract IS
  'Version probe used to fail closed when edge code and Production migrations drift.';
COMMENT ON VIEW wire_serving.items IS
  'Presentation-safe item detail with current baseline moderation exclusions applied.';
COMMENT ON VIEW wire_serving.ranked_items IS
  'Committed/superseded ranking positions without scores, diagnostics, or diversity metadata.';
COMMENT ON VIEW wire_serving.fallback_items IS
  'High-confidence fallback candidates without exposing source confidence.';
