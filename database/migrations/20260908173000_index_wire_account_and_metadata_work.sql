-- socialwire:transaction=off

-- Account lifecycle events must find their author's items without scanning the
-- corpus. General metadata claims must read their existing priority order from
-- an index rather than sorting every due cache row before claiming a small batch.
SET lock_timeout = '2min';
SET statement_timeout = '30min';

SELECT EXISTS (
  SELECT 1 FROM pg_index
  WHERE indexrelid = to_regclass('public.wire_items_author_idx')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_items_author_idx;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_items_author_idx
  ON public.wire_items (author_key);

SELECT EXISTS (
  SELECT 1 FROM pg_index
  WHERE indexrelid = to_regclass('public.wire_link_metadata_general_due_idx')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_link_metadata_general_due_idx;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_link_metadata_general_due_idx
  ON public.wire_link_metadata_cache
    (language_checked_at ASC NULLS FIRST, retry_after, canonical_key)
  WHERE status IN ('pending', 'retry', 'negative', 'fresh', 'stale', 'failed', 'fetching');

DO $$
BEGIN
  IF (
    SELECT COUNT(*) FROM pg_index
    WHERE indexrelid IN (
      to_regclass('public.wire_items_author_idx'),
      to_regclass('public.wire_link_metadata_general_due_idx')
    ) AND indisvalid AND indisready
  ) <> 2 THEN
    RAISE EXCEPTION 'valid Wire account and metadata work indexes are required';
  END IF;
END;
$$;

RESET statement_timeout;
RESET lock_timeout;
