-- Recover exact-language editions without weakening the fail-closed language gate.
-- Standard Site records with an explicit authored language remain authoritative;
-- only unknown projections may adopt language evidence already validated from the page.
WITH validated_page_languages AS (
  SELECT cache.canonical_key, cache.language_code
  FROM wire_link_metadata_cache cache
  JOIN wire_items item ON item.canonical_key = cache.canonical_key
  WHERE item.eligible = TRUE
    AND item.expires_at > NOW()
    AND item.target_kind = 'standard_site_document'
    AND item.provenance ? 'standard_site'
    AND item.language_code = 'und'
    AND cache.language_checked_at IS NOT NULL
    AND cache.language_code IS NOT NULL
    AND cache.language_code <> 'und'
    AND cache.status IN ('fresh', 'stale')
)
UPDATE wire_items item
SET language_code = validated.language_code,
    presentation_snapshot = COALESCE(item.presentation_snapshot, '{}'::jsonb)
      || jsonb_build_object('languageSource', 'content_validated_page')
FROM validated_page_languages validated
WHERE item.canonical_key = validated.canonical_key
  AND item.language_code = 'und';
