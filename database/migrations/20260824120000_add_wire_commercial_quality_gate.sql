ALTER TABLE wire_items
  ADD COLUMN IF NOT EXISTS target_kind TEXT NOT NULL DEFAULT 'external_article',
  ADD COLUMN IF NOT EXISTS commercial_score DOUBLE PRECISION NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS commercial_class TEXT NOT NULL DEFAULT 'normal',
  ADD COLUMN IF NOT EXISTS commercial_reasons JSONB NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE wire_items
  ADD CONSTRAINT wire_items_target_kind_check CHECK (
    target_kind IN ('external_article', 'standard_site_document', 'social_post',
      'profile_or_feed', 'commerce_or_ad', 'unsupported')
  ),
  ADD CONSTRAINT wire_items_commercial_score_check CHECK (
    commercial_score >= 0 AND commercial_score::text <> 'NaN'
  ),
  ADD CONSTRAINT wire_items_commercial_class_check CHECK (
    commercial_class IN ('normal', 'limited', 'probable_ad')
  ),
  ADD CONSTRAINT wire_items_commercial_reasons_array_check CHECK (
    jsonb_typeof(commercial_reasons) = 'array'
  );

UPDATE wire_items
SET target_kind = 'standard_site_document'
WHERE provenance ? 'standard_site';

UPDATE wire_items
SET target_kind = CASE
      WHEN canonical_url ~* '^https://([^.]+\.)?bsky\.app/profile/[^/]+/post/[^/?#]+/?(?:[?#].*)?$'
        THEN 'social_post'
      ELSE 'profile_or_feed'
    END,
    eligible = FALSE,
    updated_at = NOW()
WHERE source_domain = 'bsky.app' OR source_domain LIKE '%.bsky.app';

CREATE INDEX IF NOT EXISTS wire_items_quality_admission_idx
  ON wire_items (language_code, commercial_class, last_signal_at DESC, canonical_key)
  WHERE eligible = TRUE
    AND target_kind IN ('external_article', 'standard_site_document')
    AND commercial_class <> 'probable_ad';

CREATE OR REPLACE VIEW wire_serving.items
WITH (security_barrier = TRUE) AS
SELECT item.canonical_key, item.canonical_url, item.representative_uri, item.title,
  item.summary, item.published_at, item.thumbnail_url, item.source_name,
  item.source_domain, item.publication_id, item.author_name, item.provenance,
  item.author_key, COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url, item.publication_icon_url
FROM wire_items AS item
WHERE item.eligible = TRUE AND item.expires_at > CURRENT_TIMESTAMP
  AND item.target_kind IN ('external_article', 'standard_site_document')
  AND item.commercial_class <> 'probable_ad'
  AND NOT EXISTS (SELECT 1 FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam'));

CREATE OR REPLACE VIEW wire_serving.ranked_items
WITH (security_barrier = TRUE) AS
SELECT ranked.generation_id, ranked.position, item.canonical_key, item.canonical_url,
  item.representative_uri, item.title, item.summary, item.published_at, item.thumbnail_url,
  item.source_name, item.source_domain, item.publication_id, item.author_name, item.provenance,
  item.author_key, ranked.reason_codes,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url, item.publication_icon_url
FROM wire_ranked_items AS ranked
JOIN wire_rank_generations AS generation ON generation.generation_id = ranked.generation_id
JOIN wire_items AS item ON item.canonical_key = ranked.canonical_key
WHERE generation.feed_key = 'wire' AND generation.status IN ('committed', 'superseded')
  AND item.eligible = TRUE AND item.expires_at > CURRENT_TIMESTAMP
  AND item.target_kind IN ('external_article', 'standard_site_document')
  AND item.commercial_class <> 'probable_ad'
  AND NOT EXISTS (SELECT 1 FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam'));

CREATE OR REPLACE VIEW wire_serving.fallback_items
WITH (security_barrier = TRUE) AS
SELECT item.canonical_key, item.canonical_url, item.representative_uri, item.title,
  item.summary, item.published_at, item.thumbnail_url, item.source_name,
  item.source_domain, item.publication_id, item.author_name, item.provenance,
  item.author_key, item.language_code, item.topic_keys, item.first_seen_at,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url, item.publication_icon_url
FROM wire_items AS item
JOIN wire_signal_rollups AS rollup ON rollup.canonical_key = item.canonical_key
LEFT JOIN wire_link_metadata_cache AS metadata ON metadata.canonical_key = item.canonical_key
WHERE item.eligible = TRUE AND item.expires_at > CURRENT_TIMESTAMP
  AND item.target_kind IN ('external_article', 'standard_site_document')
  AND item.commercial_class <> 'probable_ad'
  AND item.source_confidence >= 0.25
  AND (rollup.shares_24h >= 3 OR rollup.recommendations_24h >= 1)
  AND (item.provenance ? 'standard_site' OR item.source_confidence >= 0.75 OR
    (metadata.source = 'open_graph' AND metadata.status IN ('fresh', 'stale')
      AND metadata.stale_until > CURRENT_TIMESTAMP
      AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
        metadata.site_name, metadata.author_name, metadata.published_at::TEXT,
        metadata.icon_url) >= 2))
  AND NOT EXISTS (SELECT 1 FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam'));

COMMENT ON VIEW wire_serving.fallback_items IS
  'Presentation-safe, engagement-gated fallback with target and commercial-quality parity.';
