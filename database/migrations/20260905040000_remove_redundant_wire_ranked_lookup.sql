-- socialwire:transaction=off

-- The unique constraint already provides the same lookup. Verify the surviving
-- index before removing a multi-GB duplicate without blocking table writes.
SET lock_timeout = '5s';
DO $$
DECLARE
  duplicate_oid oid := to_regclass('public.wire_ranked_items_lookup_idx');
  equivalent boolean;
BEGIN
  IF duplicate_oid IS NULL THEN RETURN; END IF;
  SELECT EXISTS (
    SELECT 1 FROM pg_index old_index
    JOIN pg_index kept ON kept.indrelid = old_index.indrelid
    JOIN pg_class old_class ON old_class.oid = old_index.indexrelid
    JOIN pg_class kept_class ON kept_class.oid = kept.indexrelid
    WHERE old_index.indexrelid = duplicate_oid
      AND kept.indexrelid = to_regclass('public.wire_ranked_items_generation_id_canonical_key_key')
      AND kept.indisunique AND kept.indisvalid AND kept.indisready AND kept.indislive
      AND old_index.indkey = kept.indkey
      AND old_index.indclass = kept.indclass
      AND old_index.indcollation = kept.indcollation
      AND old_index.indoption = kept.indoption
      AND old_index.indnkeyatts = kept.indnkeyatts
      AND old_class.relam = kept_class.relam
      AND old_index.indpred IS NULL AND kept.indpred IS NULL
      AND old_index.indexprs IS NULL AND kept.indexprs IS NULL
  ) INTO equivalent;
  IF NOT equivalent THEN
    RAISE EXCEPTION 'Cannot remove ranked lookup: valid equivalent unique index is absent';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conindid = duplicate_oid) THEN
    RAISE EXCEPTION 'Cannot remove ranked lookup: index backs a constraint';
  END IF;
END $$;
DROP INDEX CONCURRENTLY IF EXISTS public.wire_ranked_items_lookup_idx;
RESET lock_timeout;
