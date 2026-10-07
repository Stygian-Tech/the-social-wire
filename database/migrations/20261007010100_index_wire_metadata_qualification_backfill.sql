-- socialwire:transaction=off
SET lock_timeout = '2min';
SET statement_timeout = '30min';
SELECT EXISTS (
  SELECT 1 FROM pg_index WHERE indexrelid=to_regclass('public.wire_metadata_qualification_pending_idx')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_metadata_qualification_pending_idx;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_metadata_qualification_pending_idx
  ON public.wire_link_metadata_cache (canonical_key) WHERE open_graph_qualified IS NULL;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_index
    WHERE indexrelid=to_regclass('public.wire_metadata_qualification_pending_idx') AND indisvalid AND indisready) THEN
    RAISE EXCEPTION 'valid wire_metadata_qualification_pending_idx is required';
  END IF;
END
$$;
RESET statement_timeout;
RESET lock_timeout;
