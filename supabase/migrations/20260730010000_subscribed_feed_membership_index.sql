-- Canonical top-level Subscribed membership for batched AppView feed pagination.
--
-- Existing scope rows are rebuildable derived state. Backfill them so pagination can
-- use the optimized path immediately, before the next sidebar projection refresh.
UPDATE appview_publication_scopes
SET section_keys = section_keys || '["subscribed"]'::jsonb
WHERE NOT section_keys ? 'subscribed'
  AND (
    section_keys ? 'my'
    OR section_keys ? 'subscribed:unfoldered'
    OR EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(section_keys) AS section_key(value)
      WHERE section_key.value LIKE 'folder:%'
    )
  );

CREATE INDEX IF NOT EXISTS idx_appview_publication_scopes_section_keys
  ON appview_publication_scopes USING GIN (section_keys);

COMMENT ON INDEX idx_appview_publication_scopes_section_keys IS
  'Accelerates viewer feed membership lookups such as the canonical subscribed section key.';
