-- Align degraded Wire serving with the wire-v2 quality floor. The view keeps
-- engagement counts and metadata-cache state private while requiring a
-- conversation signal before an item can enter the cold-start fallback.

CREATE INDEX IF NOT EXISTS wire_signal_rollups_high_intent_rank_idx
  ON wire_signal_rollups (shares_24h DESC, recommendations_24h DESC, canonical_key);

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
  item.first_seen_at,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url,
  item.publication_icon_url
FROM wire_items AS item
JOIN wire_signal_rollups AS rollup
  ON rollup.canonical_key = item.canonical_key
LEFT JOIN wire_link_metadata_cache AS metadata
  ON metadata.canonical_key = item.canonical_key
WHERE item.eligible = TRUE
  AND item.expires_at > CURRENT_TIMESTAMP
  AND item.source_confidence >= 0.25
  AND (rollup.shares_24h >= 3 OR rollup.recommendations_24h >= 1)
  AND (
    item.provenance ? 'standard_site'
    OR item.source_confidence >= 0.75
    OR (
      metadata.source = 'open_graph'
      AND metadata.status IN ('fresh', 'stale')
      AND metadata.stale_until > CURRENT_TIMESTAMP
      AND num_nonnulls(
        metadata.title,
        metadata.description,
        metadata.image_url,
        metadata.site_name,
        metadata.author_name,
        metadata.published_at::TEXT,
        metadata.icon_url
      ) >= 2
    )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key
      AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
  );

COMMENT ON VIEW wire_serving.fallback_items IS
  'Presentation-safe, engagement-gated quality fallback without exposing ranking inputs.';
