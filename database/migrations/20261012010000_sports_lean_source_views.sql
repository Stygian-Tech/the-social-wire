-- Additive rank-source projections avoid rebuilding full candidate JSON on every
-- conditional request. The legacy full-generation serving contract stays intact.
-- Metadata includes only unexpired generation identity and opaque row-version
-- tokens; no raw article, Sports analysis table or user-interest grant is added.
CREATE OR REPLACE VIEW wire_serving.sports_source_heads
WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, generation.generated_at, generation.expires_at,
  generation.language, generation.is_active,
  generation.xmin::text || ':' || generation.ctid::text || ':' || generation.tableoid::text AS cache_revision
FROM sports_generations AS generation
WHERE generation.expires_at > CURRENT_TIMESTAMP;

-- Preserve original ordinal positions (including duplicates and gaps after live
-- removal). Joining the current security-barrier item view retains every item,
-- target-kind, commercial, label, expiry and generation-language eligibility gate.
CREATE OR REPLACE VIEW wire_serving.sports_source_candidates
WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, candidate.ordinality AS ordinal,
  candidate.value->'item'->>'itemId' AS item_id, candidate.value AS candidate
FROM sports_generations AS generation
CROSS JOIN LATERAL jsonb_array_elements(generation.payload)
  WITH ORDINALITY AS candidate(value, ordinality)
JOIN wire_serving.items AS item
  ON item.canonical_key = candidate.value->'item'->>'itemId'
WHERE generation.expires_at > CURRENT_TIMESTAMP
  AND (generation.language = 'und' OR item.language_code = generation.language);

-- Finance retains its full legacy generation adapter while exposing the same
-- metadata/current-eligible-candidate split as Sports.
CREATE OR REPLACE VIEW wire_serving.finance_source_heads
WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, generation.generated_at, generation.expires_at,
  generation.language, generation.is_active,
  generation.xmin::text || ':' || generation.ctid::text || ':' || generation.tableoid::text AS cache_revision
FROM finance_generations AS generation
WHERE generation.expires_at > CURRENT_TIMESTAMP;

CREATE OR REPLACE VIEW wire_serving.finance_source_candidates
WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, candidate.ordinality AS ordinal,
  candidate.value->'item'->>'itemId' AS item_id, candidate.value AS candidate
FROM finance_generations AS generation
CROSS JOIN LATERAL jsonb_array_elements(generation.payload)
  WITH ORDINALITY AS candidate(value, ordinality)
JOIN wire_serving.items AS item
  ON item.canonical_key = candidate.value->'item'->>'itemId'
WHERE generation.expires_at > CURRENT_TIMESTAMP
  AND (generation.language = 'und' OR item.language_code = generation.language);

-- Instrument references come from the RAW immutable generation, including
-- candidates excluded by today's item gates, exactly as the legacy view does.
-- Resolve one distinct reference set before joining instrument rows rather than
-- rescanning every candidate association once per instrument.
CREATE OR REPLACE VIEW wire_serving.finance_source_instruments
WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, instrument.instrument_id,
  instrument.xmin::text || ':' || instrument.ctid::text || ':' || instrument.tableoid::text AS cache_revision,
  instrument.payload
FROM finance_generations AS generation
CROSS JOIN LATERAL (
  SELECT DISTINCT association.value->>'instrumentID' AS instrument_id
  FROM jsonb_array_elements(generation.payload) AS candidate(value)
  CROSS JOIN LATERAL jsonb_array_elements(candidate.value->'analysis'->'associations') AS association(value)
) AS referenced
JOIN finance_instruments AS instrument ON instrument.instrument_id = referenced.instrument_id
WHERE generation.expires_at > CURRENT_TIMESTAMP;

-- Match existing item-view readers exactly. View-owner access resolves the raw
-- joins; consumers acquire no SELECT privilege on the underlying private tables.
DO $$
DECLARE reader RECORD;
BEGIN
  FOR reader IN
    SELECT DISTINCT privilege.grantee FROM pg_class relation
    CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault('r', relation.relowner))) privilege
    WHERE relation.oid = 'wire_serving.items'::regclass
      AND privilege.privilege_type = 'SELECT' AND privilege.grantee <> relation.relowner
  LOOP
    IF reader.grantee = 0 THEN
      GRANT SELECT ON wire_serving.sports_source_heads, wire_serving.sports_source_candidates, wire_serving.finance_source_heads, wire_serving.finance_source_candidates, wire_serving.finance_source_instruments TO PUBLIC;
    ELSE
      EXECUTE format('GRANT SELECT ON wire_serving.sports_source_heads, wire_serving.sports_source_candidates, wire_serving.finance_source_heads, wire_serving.finance_source_candidates, wire_serving.finance_source_instruments TO %I', pg_get_userbyid(reader.grantee));
    END IF;
  END LOOP;
END $$;
