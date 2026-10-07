-- socialwire:transaction=off
SET lock_timeout = '2min';
SET statement_timeout = '30min';
SELECT EXISTS (
  SELECT 1 FROM pg_index WHERE indexrelid=to_regclass('public.wire_items_representative_uri_idx')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_items_representative_uri_idx;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_items_representative_uri_idx
  ON public.wire_items (representative_uri) WHERE representative_uri IS NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_index
    WHERE indexrelid=to_regclass('public.wire_items_representative_uri_idx') AND indisvalid AND indisready) THEN
    RAISE EXCEPTION 'valid wire_items_representative_uri_idx is required';
  END IF;
END
$$;
RESET statement_timeout;
RESET lock_timeout;
