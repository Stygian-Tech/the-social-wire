-- Preserve the legacy admission predicate as a narrow field computed on writes.
-- Nullable addition has no table rewrite or automatic corpus backfill.
SET LOCAL lock_timeout = '2s';
ALTER TABLE wire_link_metadata_cache ADD COLUMN open_graph_qualified boolean;

CREATE FUNCTION wire_metadata_qualification_sync() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.open_graph_qualified IS NOT NULL
    AND NEW.open_graph_qualified IS NOT DISTINCT FROM OLD.open_graph_qualified
    AND ROW(NEW.source, NEW.status, NEW.title IS NULL, NEW.description IS NULL,
      NEW.image_url IS NULL, NEW.site_name IS NULL, NEW.author_name IS NULL,
      NEW.published_at IS NULL, NEW.icon_url IS NULL)
      IS NOT DISTINCT FROM ROW(OLD.source, OLD.status, OLD.title IS NULL,
      OLD.description IS NULL, OLD.image_url IS NULL, OLD.site_name IS NULL,
      OLD.author_name IS NULL, OLD.published_at IS NULL, OLD.icon_url IS NULL) THEN
    RETURN NEW;
  END IF;
  NEW.open_graph_qualified := NEW.source = 'open_graph'
    AND NEW.status IN ('fresh','stale')
    AND num_nonnulls(NEW.title,NEW.description,NEW.image_url,NEW.site_name,
      NEW.author_name,NEW.published_at::text,NEW.icon_url) >= 2;
  RETURN NEW;
END
$$;
CREATE TRIGGER wire_metadata_qualification_sync
  BEFORE INSERT OR UPDATE OF source,status,title,description,image_url,site_name,
    author_name,published_at,icon_url,open_graph_qualified
  ON wire_link_metadata_cache
  FOR EACH ROW EXECUTE FUNCTION wire_metadata_qualification_sync();

-- Resumable independent batches. The caller must set statement_timeout before
-- issuing this statement; changing it inside a function cannot bound that call.
CREATE FUNCTION wire_backfill_metadata_qualification(batch_size integer DEFAULT 500)
RETURNS integer LANGUAGE plpgsql SET lock_timeout = '500ms' AS $$
DECLARE affected integer;
BEGIN
  IF batch_size IS NULL OR batch_size < 1 OR batch_size > 5000 THEN
    RAISE EXCEPTION 'metadata qualification batch_size must be 1..5000';
  END IF;
  WITH pending AS MATERIALIZED (
    SELECT canonical_key FROM wire_link_metadata_cache
    WHERE open_graph_qualified IS NULL ORDER BY canonical_key
    LIMIT batch_size FOR UPDATE SKIP LOCKED
  )
  UPDATE wire_link_metadata_cache metadata SET open_graph_qualified = NULL
  FROM pending WHERE metadata.canonical_key = pending.canonical_key;
  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END
$$;
COMMENT ON COLUMN wire_link_metadata_cache.open_graph_qualified IS
  'Non-time legacy Open Graph admission predicate. NULL means not yet backfilled; stale_until is checked dynamically.';

-- Preserve the restricted view shape, security barrier and existing grants.
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
  COALESCE(metadata.stale_until > CURRENT_TIMESTAMP, FALSE) AS has_usable_open_graph,
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
  AND (item.provenance ? 'standard_site' OR COALESCE(metadata.stale_until > CURRENT_TIMESTAMP, FALSE))) AS baseline_admitted
FROM wire_items AS item
JOIN wire_signal_rollups AS rollup ON rollup.canonical_key = item.canonical_key
LEFT JOIN (
          SELECT canonical_key, stale_until FROM wire_link_metadata_cache
          WHERE open_graph_qualified = TRUE
          UNION ALL
          SELECT canonical_key, stale_until FROM wire_link_metadata_cache metadata
          WHERE open_graph_qualified IS NULL AND metadata.source = 'open_graph'
            AND metadata.status IN ('fresh', 'stale')
            AND num_nonnulls(metadata.title, metadata.description, metadata.image_url,
              metadata.site_name, metadata.author_name, metadata.published_at::text,
              metadata.icon_url) >= 2
        ) AS metadata ON metadata.canonical_key = item.canonical_key
WHERE item.eligible = TRUE AND item.expires_at > CURRENT_TIMESTAMP
  AND item.target_kind IN ('external_article', 'standard_site_document')
  AND item.commercial_class <> 'probable_ad'
  AND NOT EXISTS (SELECT 1 FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam'));
