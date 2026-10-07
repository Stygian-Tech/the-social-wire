package wireworkercore

// Matches the effective merged presentation row and seeds recoverable metadata work.
const upsertItemSQL = `WITH upserted_item AS (
INSERT INTO wire_items
  (canonical_key, canonical_url, representative_uri, publication_id, author_key,
   source_domain, source_name, author_name, title, summary, thumbnail_url,
   publication_homepage_url, publication_icon_url,
   language_code, topic_keys, presentation_snapshot, provenance, published_at,
   first_seen_at, last_seen_at, last_signal_at,
   source_confidence, eligible, target_kind, commercial_score, commercial_class,
   commercial_reasons, expires_at, updated_at)
VALUES
  ($1, $2, $3, $4,
   $5, $6, $7, $8, $9, $10, $11,
   $12, $13,
   $14, $15::jsonb, $16::jsonb, $17::jsonb,
   $18, $19, $19, $20, $21, $22,
   $23,
   $24, $25,
   $26::jsonb, $27, $19)
ON CONFLICT (canonical_key) DO UPDATE SET
  canonical_url = EXCLUDED.canonical_url,
  representative_uri = COALESCE(wire_items.representative_uri, EXCLUDED.representative_uri),
  publication_id = COALESCE(wire_items.publication_id, EXCLUDED.publication_id),
  author_key = COALESCE(wire_items.author_key, EXCLUDED.author_key),
  author_name = COALESCE(wire_items.author_name, EXCLUDED.author_name),
  source_name = CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN EXCLUDED.source_name ELSE wire_items.source_name END,
  title = CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN EXCLUDED.title ELSE wire_items.title END,
  summary = CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN COALESCE(EXCLUDED.summary, wire_items.summary) ELSE wire_items.summary END,
  thumbnail_url = CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN COALESCE(EXCLUDED.thumbnail_url, wire_items.thumbnail_url) ELSE wire_items.thumbnail_url END,
  presentation_snapshot = CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN EXCLUDED.presentation_snapshot ELSE wire_items.presentation_snapshot END,
  publication_homepage_url = COALESCE(
    EXCLUDED.publication_homepage_url, wire_items.publication_homepage_url),
  publication_icon_url = COALESCE(
    EXCLUDED.publication_icon_url, wire_items.publication_icon_url),
  language_code = CASE
    WHEN EXCLUDED.presentation_snapshot->>'metadataSource' = 'standard_site'
    THEN EXCLUDED.language_code
    ELSE wire_items.language_code END,
  topic_keys = CASE WHEN jsonb_array_length(wire_items.topic_keys) = 0
    THEN EXCLUDED.topic_keys ELSE wire_items.topic_keys END,
  provenance = (
    SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
    FROM (
      SELECT DISTINCT value
      FROM jsonb_array_elements_text(wire_items.provenance || EXCLUDED.provenance)
    ) unique_provenance
  ), target_kind = CASE
    WHEN wire_items.target_kind NOT IN ('external_article', 'standard_site_document')
      THEN wire_items.target_kind
    WHEN EXCLUDED.target_kind NOT IN ('external_article', 'standard_site_document')
      THEN EXCLUDED.target_kind
    WHEN wire_items.target_kind = 'standard_site_document' THEN wire_items.target_kind
    ELSE EXCLUDED.target_kind END,
  commercial_score = GREATEST(wire_items.commercial_score, EXCLUDED.commercial_score),
  commercial_class = CASE
    WHEN wire_items.commercial_score > EXCLUDED.commercial_score
    THEN wire_items.commercial_class ELSE EXCLUDED.commercial_class END,
  commercial_reasons = CASE
    WHEN wire_items.commercial_score > EXCLUDED.commercial_score
    THEN wire_items.commercial_reasons ELSE EXCLUDED.commercial_reasons END,
  published_at = COALESCE(wire_items.published_at, EXCLUDED.published_at),
  last_seen_at = EXCLUDED.last_seen_at,
  last_signal_at = COALESCE(EXCLUDED.last_signal_at, wire_items.last_signal_at),
  eligible = wire_items.eligible AND EXCLUDED.eligible,
  source_confidence = GREATEST(wire_items.source_confidence, EXCLUDED.source_confidence),
  expires_at = GREATEST(wire_items.expires_at, EXCLUDED.expires_at), updated_at = EXCLUDED.updated_at
WHERE CASE
  -- Advancing observations already require an update; avoid merging JSON twice.
  WHEN wire_items.last_seen_at IS DISTINCT FROM EXCLUDED.last_seen_at
    OR wire_items.last_signal_at IS DISTINCT FROM
      COALESCE(EXCLUDED.last_signal_at, wire_items.last_signal_at)
    OR wire_items.expires_at IS DISTINCT FROM
      GREATEST(wire_items.expires_at, EXCLUDED.expires_at)
  THEN TRUE
  ELSE ROW(
  wire_items.canonical_url,
  wire_items.representative_uri,
  wire_items.publication_id,
  wire_items.author_key,
  wire_items.author_name,
  wire_items.source_name,
  wire_items.title,
  wire_items.summary,
  wire_items.thumbnail_url,
  wire_items.presentation_snapshot,
  wire_items.publication_homepage_url,
  wire_items.publication_icon_url,
  wire_items.language_code,
  wire_items.topic_keys,
  wire_items.provenance,
  wire_items.target_kind,
  wire_items.commercial_score,
  wire_items.commercial_class,
  wire_items.commercial_reasons,
  wire_items.published_at,
  wire_items.eligible,
  wire_items.source_confidence)
  IS DISTINCT FROM ROW(
  EXCLUDED.canonical_url,
  COALESCE(wire_items.representative_uri, EXCLUDED.representative_uri),
  COALESCE(wire_items.publication_id, EXCLUDED.publication_id),
  COALESCE(wire_items.author_key, EXCLUDED.author_key),
  COALESCE(wire_items.author_name, EXCLUDED.author_name),
  CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN EXCLUDED.source_name ELSE wire_items.source_name END,
  CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN EXCLUDED.title ELSE wire_items.title END,
  CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN COALESCE(EXCLUDED.summary, wire_items.summary) ELSE wire_items.summary END,
  CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN COALESCE(EXCLUDED.thumbnail_url, wire_items.thumbnail_url) ELSE wire_items.thumbnail_url END,
  CASE
    WHEN COALESCE((EXCLUDED.presentation_snapshot->>'sourcePriority')::integer, 0)
      >= COALESCE((wire_items.presentation_snapshot->>'sourcePriority')::integer, 0)
    THEN EXCLUDED.presentation_snapshot ELSE wire_items.presentation_snapshot END,
  COALESCE(
    EXCLUDED.publication_homepage_url, wire_items.publication_homepage_url),
  COALESCE(
    EXCLUDED.publication_icon_url, wire_items.publication_icon_url),
  CASE
    WHEN EXCLUDED.presentation_snapshot->>'metadataSource' = 'standard_site'
    THEN EXCLUDED.language_code
    ELSE wire_items.language_code END,
  CASE WHEN jsonb_array_length(wire_items.topic_keys) = 0
    THEN EXCLUDED.topic_keys ELSE wire_items.topic_keys END,
  (
    SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
    FROM (
      SELECT DISTINCT value
      FROM jsonb_array_elements_text(wire_items.provenance || EXCLUDED.provenance)
    ) unique_provenance
  ),
  CASE
    WHEN wire_items.target_kind NOT IN ('external_article', 'standard_site_document')
      THEN wire_items.target_kind
    WHEN EXCLUDED.target_kind NOT IN ('external_article', 'standard_site_document')
      THEN EXCLUDED.target_kind
    WHEN wire_items.target_kind = 'standard_site_document' THEN wire_items.target_kind
    ELSE EXCLUDED.target_kind END,
  GREATEST(wire_items.commercial_score, EXCLUDED.commercial_score),
  CASE
    WHEN wire_items.commercial_score > EXCLUDED.commercial_score
    THEN wire_items.commercial_class ELSE EXCLUDED.commercial_class END,
  CASE
    WHEN wire_items.commercial_score > EXCLUDED.commercial_score
    THEN wire_items.commercial_reasons ELSE EXCLUDED.commercial_reasons END,
  COALESCE(wire_items.published_at, EXCLUDED.published_at),
  wire_items.eligible AND EXCLUDED.eligible,
  GREATEST(wire_items.source_confidence, EXCLUDED.source_confidence))
END
RETURNING canonical_key, canonical_url, eligible, expires_at
)
INSERT INTO wire_link_metadata_cache
  (canonical_key, canonical_url, source, status, retry_after, failure_count, updated_at)
SELECT canonical_key, canonical_url, 'fallback', 'pending', $19, 0, $19
FROM (
  SELECT canonical_key, canonical_url, eligible, expires_at FROM upserted_item
  UNION ALL
  SELECT canonical_key, canonical_url, eligible, expires_at FROM wire_items
  WHERE canonical_key = $1
    AND NOT EXISTS (SELECT 1 FROM upserted_item)
) item
WHERE eligible AND expires_at > $19 AND canonical_url LIKE 'https://%'
  AND NOT EXISTS (
    SELECT 1 FROM wire_link_metadata_cache cache
    WHERE cache.canonical_key = item.canonical_key
  )
ON CONFLICT (canonical_key) DO NOTHING`
