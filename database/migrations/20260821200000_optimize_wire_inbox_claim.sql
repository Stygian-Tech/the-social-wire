-- socialwire:transaction=off

-- The worker claims globally across every environment/source generation. Order
-- the active subset by the timestamp at which each row is actually eligible so
-- the claim does not scan an index prefixed by an unknown environment/generation.

DO $$
DECLARE
  existing_claim_index REGCLASS :=
    to_regclass('public.wire_ingestion_inbox_claim_idx');
  existing_claim_index_bytes BIGINT;
BEGIN
  IF existing_claim_index IS NULL THEN
    RAISE EXCEPTION 'existing Wire inbox claim index is missing';
  END IF;

  existing_claim_index_bytes := pg_relation_size(existing_claim_index);
  IF existing_claim_index_bytes > 1610612736 THEN
    RAISE EXCEPTION
      'Wire inbox claim index is % bytes, above the 1.5 GiB online-build safety limit',
      existing_claim_index_bytes;
  END IF;
END
$$;

SELECT EXISTS (
  SELECT 1
  FROM pg_class index_relation
  JOIN pg_index index_state
    ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid =
      to_regclass('public.wire_ingestion_inbox_claimable_global_v2_idx')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset

\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS
  public.wire_ingestion_inbox_claimable_global_v2_idx;
\endif

CREATE INDEX CONCURRENTLY IF NOT EXISTS
  wire_ingestion_inbox_claimable_global_v2_idx
ON public.wire_ingestion_inbox (
  (
    CASE
      WHEN status = 'leased' THEN lease_expires_at
      ELSE next_attempt_at
    END
  ),
  seq,
  environment,
  source_generation
)
WHERE status IN ('pending', 'leased', 'retry');

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_class index_relation
    JOIN pg_index index_state
      ON index_state.indexrelid = index_relation.oid
    WHERE index_relation.oid =
        to_regclass('public.wire_ingestion_inbox_claimable_global_v2_idx')
      AND NOT index_state.indisvalid
  ) THEN
    RAISE EXCEPTION 'invalid global Wire inbox claim index remains';
  END IF;
END
$$;
