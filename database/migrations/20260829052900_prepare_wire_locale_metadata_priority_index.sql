-- socialwire:transaction=off

-- Production can retain an invalid index shell when the first concurrent build
-- loses its short lock-acquisition window. This preparation sorts immediately
-- before the original migration, repairs that shell, and gives the live table
-- a bounded but practical window without blocking ordinary reads or writes.

SET lock_timeout = '2min';
SET statement_timeout = '30min';

SELECT EXISTS (
  SELECT 1
  FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass(
    'public.wire_items_unclassified_metadata_priority_idx'
  )
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_items_unclassified_metadata_priority_idx;
\endif

CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_items_unclassified_metadata_priority_idx
  ON wire_items (last_signal_at DESC NULLS LAST, canonical_key)
  WHERE language_code = 'und'
    AND eligible = TRUE
    AND target_kind IN ('external_article', 'standard_site_document')
    AND commercial_class <> 'probable_ad'
    AND source_confidence >= 0.25;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_class index_relation
    JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
    WHERE index_relation.oid = to_regclass(
      'public.wire_items_unclassified_metadata_priority_idx'
    )
      AND index_state.indisvalid
  ) THEN
    RAISE EXCEPTION 'valid Wire locale metadata priority index is required';
  END IF;
END;
$$;

COMMENT ON INDEX wire_items_unclassified_metadata_priority_idx IS
  'Prioritizes current unclassified Wire stories for bounded metadata language recovery.';

RESET statement_timeout;
RESET lock_timeout;
