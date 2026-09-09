-- socialwire:transaction=off

-- Every event currently maintains both a primary-key index and an equivalent
-- lookup index. Preflight all three before dropping any; interrupted concurrent
-- drops can be retried. Keep replay ordering, uniqueness, and every stored row.
SET lock_timeout = '5s';
DO $$
DECLARE
  target RECORD;
  duplicate_oid oid;
BEGIN
  FOR target IN SELECT * FROM (VALUES
    ('operations_change_events', 'idx_operations_change_events_replay', 'operations_change_events_pkey'),
    ('operations_events', 'idx_operations_events_environment_id', 'operations_events_pkey'),
    ('operations_trace_spans', 'idx_operations_traces_environment_id', 'operations_trace_spans_pkey')
  ) AS indexes(table_name, duplicate_name, retained_name)
  LOOP
    duplicate_oid := to_regclass('public.' || target.duplicate_name);
    IF duplicate_oid IS NULL THEN CONTINUE; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_index old_index
      JOIN pg_index kept ON kept.indrelid = old_index.indrelid
      JOIN pg_class old_class ON old_class.oid = old_index.indexrelid
      JOIN pg_class kept_class ON kept_class.oid = kept.indexrelid
      WHERE old_index.indexrelid = duplicate_oid
        AND old_index.indrelid = to_regclass('public.' || target.table_name)
        AND kept.indexrelid = to_regclass('public.' || target.retained_name)
        AND kept.indisprimary AND kept.indisunique
        AND kept.indisvalid AND kept.indisready AND kept.indislive
        AND old_index.indkey = kept.indkey
        AND old_index.indclass = kept.indclass
        AND old_index.indcollation = kept.indcollation
        AND old_index.indoption = kept.indoption
        AND old_index.indnkeyatts = kept.indnkeyatts
        AND old_index.indnatts = kept.indnatts
        AND old_class.relam = kept_class.relam
        AND old_index.indpred IS NULL AND kept.indpred IS NULL
        AND old_index.indexprs IS NULL AND kept.indexprs IS NULL
    ) THEN
      RAISE EXCEPTION 'Cannot remove %: valid equivalent primary-key index is absent', target.duplicate_name;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conindid = duplicate_oid)
      OR EXISTS (SELECT 1 FROM pg_depend
        WHERE refclassid = 'pg_class'::regclass AND refobjid = duplicate_oid)
      OR EXISTS (SELECT 1 FROM pg_index WHERE indexrelid = duplicate_oid
        AND (indisreplident OR indisclustered)) THEN
      RAISE EXCEPTION 'Cannot remove %: index has a constraint, dependency, or identity role', target.duplicate_name;
    END IF;
  END LOOP;
END $$;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_operations_change_events_replay;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_operations_events_environment_id;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_operations_traces_environment_id;
RESET lock_timeout;
