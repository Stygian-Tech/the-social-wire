-- Keep the old fallback view unchanged during Migrator -> Corpus Edge rollout.
-- This separate restricted projection supplies the shared baseline ranker.
CREATE OR REPLACE VIEW wire_serving.fallback_candidates
WITH (security_barrier = TRUE) AS
SELECT item.canonical_key, item.canonical_url, item.representative_uri, item.title,
  item.summary, item.published_at, item.thumbnail_url, item.source_name,
  item.source_domain, item.publication_id, item.author_name, item.provenance,
  item.author_key, item.language_code, item.topic_keys, item.first_seen_at,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url, item.publication_icon_url,
  item.source_confidence, item.target_kind, item.commercial_class, item.commercial_score,
  (item.provenance ? 'standard_site') AS is_standard_site,
  COALESCE(metadata.source = 'open_graph' AND metadata.status IN ('fresh', 'stale')
    AND metadata.stale_until > CURRENT_TIMESTAMP
    AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
      metadata.site_name, metadata.author_name, metadata.published_at::TEXT,
      metadata.icon_url) >= 2, FALSE) AS has_usable_open_graph,
  COALESCE(NULLIF(BTRIM(item.thumbnail_url), '') ~* '^https?://', FALSE) AS has_usable_thumbnail,
  rollup.baseline_last_signal_at, rollup.baseline_distinct_actors_1h,
  rollup.baseline_distinct_actors_24h, rollup.baseline_distinct_actors_7d,
  rollup.baseline_signals_1h, rollup.baseline_signals_24h,
  rollup.baseline_signals_7d, rollup.communities_24h,
  rollup.primary_community_key_hash, rollup.baseline_recommendations_24h,
  rollup.positive_feedback_24h, rollup.negative_feedback_24h,
  rollup.baseline_shares_1h, rollup.baseline_shares_24h,
  rollup.baseline_distinct_likers_24h, rollup.baseline_likes_1h,
  rollup.baseline_likes_24h, rollup.distinct_reposters_24h,
  rollup.reposts_1h, rollup.reposts_24h,
  -- Catalog qualification only: ranker admission follows the bounded candidate cap.
  (item.source_confidence >= 0.25
  AND item.source_confidence < 'Infinity'::double precision
  AND COALESCE(item.published_at, item.first_seen_at) >= CURRENT_TIMESTAMP - INTERVAL '30 days'
  AND (rollup.baseline_shares_24h >= 3 OR rollup.baseline_recommendations_24h >= 1
    OR ((item.provenance ? 'standard_site') AND item.source_confidence >= 0.75
      AND COALESCE(item.published_at, item.first_seen_at) >= CURRENT_TIMESTAMP - INTERVAL '3 days'
      AND rollup.baseline_shares_24h >= 1))
  AND (item.provenance ? 'standard_site' OR COALESCE(metadata.source = 'open_graph' AND metadata.status IN ('fresh', 'stale')
    AND metadata.stale_until > CURRENT_TIMESTAMP
    AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
      metadata.site_name, metadata.author_name, metadata.published_at::TEXT,
      metadata.icon_url) >= 2, FALSE))) AS baseline_admitted
FROM wire_items AS item
JOIN wire_signal_rollups AS rollup ON rollup.canonical_key = item.canonical_key
LEFT JOIN wire_link_metadata_cache AS metadata ON metadata.canonical_key = item.canonical_key
WHERE item.eligible = TRUE AND item.expires_at > CURRENT_TIMESTAMP
  AND item.target_kind IN ('external_article', 'standard_site_document')
  AND item.commercial_class <> 'probable_ad'
  AND NOT EXISTS (SELECT 1 FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam'));

COMMENT ON VIEW wire_serving.fallback_candidates IS
  'Baseline fallback ranking inputs; catalog admission is separate from candidate selection, with no raw signals or viewer state.';

-- Preserve existing serving-reader access without granting raw-table access or
-- guessing hosted role names. New views do not inherit grants from older views.
DO $$
DECLARE
  reader RECORD;
BEGIN
  FOR reader IN
    SELECT DISTINCT privilege.grantee
    FROM pg_class relation
    CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault('r', relation.relowner))) privilege
    WHERE relation.oid = 'wire_serving.fallback_items'::regclass
      AND privilege.privilege_type = 'SELECT' AND privilege.grantee <> relation.relowner
  LOOP
    IF reader.grantee = 0 THEN
      GRANT SELECT ON wire_serving.fallback_candidates TO PUBLIC;
    ELSE
      EXECUTE format('GRANT SELECT ON wire_serving.fallback_candidates TO %I',
        pg_get_userbyid(reader.grantee));
    END IF;
  END LOOP;
END
$$;
