-- socialwire:transaction=off
-- Classifiers/rankers can read qualified keys and dynamic expiry from a compact
-- index; the existing nullable-row index supports legacy fallback during backfill.
SET lock_timeout = '2min';
SET statement_timeout = '30min';
SELECT EXISTS (
  SELECT 1 FROM pg_index WHERE indexrelid=to_regclass('public.wire_metadata_qualified_key_idx')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_metadata_qualified_key_idx;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_metadata_qualified_key_idx
  ON public.wire_link_metadata_cache (canonical_key) INCLUDE (stale_until)
  WHERE open_graph_qualified=TRUE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_index
    WHERE indexrelid=to_regclass('public.wire_metadata_qualified_key_idx') AND indisvalid AND indisready) THEN
    RAISE EXCEPTION 'valid wire_metadata_qualified_key_idx is required';
  END IF;
END
$$;
RESET statement_timeout;
RESET lock_timeout;
