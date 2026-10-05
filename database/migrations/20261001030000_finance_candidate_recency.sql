-- socialwire:transaction=off

-- Finance projection must reach recent quality candidates through ordered index
-- traversal rather than sorting the complete admitted corpus. Concurrent builds
-- preserve ordinary traffic; retries repair an interrupted invalid index shell.
SET lock_timeout = '2min';
SET statement_timeout = '30min';

SELECT EXISTS (
  SELECT 1 FROM pg_class relation JOIN pg_index state ON state.indexrelid=relation.oid
  WHERE relation.oid=to_regclass('public.finance_candidate_recency') AND NOT state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.finance_candidate_recency;
\endif

CREATE INDEX CONCURRENTLY IF NOT EXISTS finance_candidate_recency
  ON wire_items (updated_at DESC, canonical_key)
  WHERE eligible = TRUE
    AND target_kind IN ('external_article', 'standard_site_document')
    AND commercial_class <> 'probable_ad'
    AND source_confidence >= 0.75;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class relation JOIN pg_index state ON state.indexrelid=relation.oid
    WHERE relation.oid=to_regclass('public.finance_candidate_recency') AND state.indisvalid
  ) THEN
    RAISE EXCEPTION 'valid Finance candidate recency index is required';
  END IF;
END;
$$;
ANALYZE wire_items;
RESET statement_timeout;
RESET lock_timeout;
