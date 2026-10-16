-- socialwire:transaction=off

-- Candidate batches need expiry alongside their ordered scope keys. Keeping it
-- in the index avoids fetching a heap page for every history candidate before
-- the global page limit. Payload hydration still happens only for that batch.
-- Retain the older indexes for rollback and other query shapes.
SET lock_timeout = '2min';
SET statement_timeout = '30min';

SELECT EXISTS (
  SELECT 1 FROM pg_index
  WHERE indexrelid=to_regclass('public.idx_content_items_author_site_feed_cover')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_content_items_author_site_feed_cover;
\endif

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_content_items_author_site_feed_cover
  ON content_items (author_did, publication_site, created_at DESC, uri DESC)
  INCLUDE (expires_at);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_index
    WHERE indexrelid=to_regclass('public.idx_content_items_author_site_feed_cover')
      AND indisvalid AND indisready
  ) THEN
    RAISE EXCEPTION 'valid covering index for scoped feed candidates is required';
  END IF;
END;
$$;
RESET statement_timeout;
RESET lock_timeout;
