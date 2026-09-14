-- socialwire:transaction=off
SET lock_timeout = '5s';
SET statement_timeout = '30min';
SELECT EXISTS (
  SELECT 1 FROM pg_index WHERE indexrelid = to_regclass('public.wire_metadata_priority_work_order_idx')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_metadata_priority_work_order_idx;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_metadata_priority_work_order_idx ON wire_metadata_priority_work
  (last_signal_at DESC NULLS LAST, retry_after, canonical_key)
  WHERE item_present AND cache_present AND language_code = 'und' AND eligible
    AND target_kind IN ('external_article', 'standard_site_document')
    AND commercial_class <> 'probable_ad' AND source_confidence >= 0.25
    AND language_checked_at IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_index
    WHERE indexrelid = to_regclass('wire_metadata_priority_work_order_idx') AND indisvalid AND indisready) THEN
    RAISE EXCEPTION 'valid metadata priority work index is required';
  END IF;
END $$;
RESET statement_timeout;
RESET lock_timeout;
