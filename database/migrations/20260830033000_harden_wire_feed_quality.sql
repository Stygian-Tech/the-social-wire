ALTER TABLE wire_items
  DROP CONSTRAINT IF EXISTS wire_items_target_kind_check;

UPDATE wire_items
SET target_kind = 'operational_status', eligible = FALSE, updated_at = NOW()
WHERE lower(source_domain) ~ '^(status|statuspage)\.'
  OR lower(source_domain) IN (
    'statuspage.io', 'status.io', 'instatus.com', 'betteruptime.com',
    'statuspal.io', 'statuscast.com'
  )
  OR lower(source_domain) ~ '\.(statuspage\.io|status\.io|instatus\.com|betteruptime\.com|statuspal\.io|statuscast\.com)$';

ALTER TABLE wire_items
  ADD CONSTRAINT wire_items_target_kind_check CHECK (
    target_kind IN ('external_article', 'standard_site_document', 'social_post',
      'profile_or_feed', 'commerce_or_ad', 'operational_status', 'unsupported')
  );

-- Rebuild authoritative Standard Site language evidence from retained source records.
-- A missing record language stays und even when the linked page declares a locale.
WITH latest_standard_record AS (
  SELECT DISTINCT ON (source_uri)
    source_uri,
    raw_language,
    event_time,
    seq
  FROM (
    SELECT
      'at://' || repo_did || '/' || collection || '/' || record_key AS source_uri,
      COALESCE(
        payload #>> '{commit,record,lang}',
        payload #>> '{commit,record,language}'
      ) AS raw_language,
      event_time,
      seq
    FROM wire_ingestion_inbox
    WHERE collection IN ('site.standard.document', 'site.standard.entry')
      AND operation IN ('create', 'update')
      AND jsonb_typeof(payload #> '{commit,record}') = 'object'
  ) retained
  ORDER BY source_uri, event_time DESC, seq DESC
), authoritative_standard_language AS (
  SELECT source_uri, event_time, seq,
    CASE
      WHEN lower(split_part(replace(raw_language, '_', '-'), '-', 1)) ~ '^[a-z]{2,3}$'
        THEN lower(split_part(replace(raw_language, '_', '-'), '-', 1))
      ELSE NULL
    END AS language_code
  FROM latest_standard_record
), authoritative_language_by_item AS (
  SELECT DISTINCT ON (alias.canonical_key)
    alias.canonical_key,
    record.language_code
  FROM authoritative_standard_language record
  JOIN wire_item_aliases alias
    ON alias.alias_key = record.source_uri AND alias.alias_type = 'at_uri'
  ORDER BY alias.canonical_key, record.event_time DESC, record.seq DESC
), resolved_standard_language AS (
  SELECT item.canonical_key, record.language_code
  FROM wire_items item
  LEFT JOIN authoritative_language_by_item record
    ON record.canonical_key = item.canonical_key
  WHERE item.provenance ? 'standard_site'
)
UPDATE wire_items item
SET language_code = COALESCE(resolved.language_code, 'und'),
    presentation_snapshot = jsonb_set(
      COALESCE(item.presentation_snapshot, '{}'::jsonb),
      '{languageSource}',
      to_jsonb(CASE WHEN resolved.language_code IS NULL
        THEN 'unknown'::text ELSE 'standard_site_record'::text END),
      TRUE
    ),
    updated_at = NOW()
FROM resolved_standard_language resolved
WHERE resolved.canonical_key = item.canonical_key;

-- Sharing-post langs describe the commentary, not the linked target. Preserve only
-- external languages that were independently checked against page metadata.
UPDATE wire_items item
SET language_code = 'und',
    presentation_snapshot = jsonb_set(
      COALESCE(item.presentation_snapshot, '{}'::jsonb),
      '{languageSource}', to_jsonb('unknown'::text), TRUE
    ),
    updated_at = NOW()
WHERE NOT (item.provenance ? 'standard_site')
  AND item.language_code <> 'und'
  AND NOT EXISTS (
    SELECT 1
    FROM wire_link_metadata_cache metadata
    WHERE metadata.canonical_key = item.canonical_key
      AND metadata.language_checked_at IS NOT NULL
      AND metadata.language_code = item.language_code
  );

COMMENT ON COLUMN wire_items.target_kind IS
  'Canonical target admission kind; operational status pages are retained for audit but never served.';
