-- Keep every live security-barrier item gate while bounding its work to the
-- immutable generation's candidate keys. An ordinary join can hash/scan the
-- entire wide item corpus before checking a small generation. The lateral LIMIT
-- retains a parameterized point lookup for each key, including on warm requests.
-- canonical_key is unique, so LIMIT 1 preserves eligibility and duplicate/order
-- semantics. CREATE OR REPLACE preserves existing view ownership and grants.
CREATE OR REPLACE VIEW wire_serving.sports_source_candidates
WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, candidate.ordinality AS ordinal,
  candidate.value->'item'->>'itemId' AS item_id, candidate.value AS candidate
FROM sports_generations AS generation
CROSS JOIN LATERAL jsonb_array_elements(generation.payload)
  WITH ORDINALITY AS candidate(value, ordinality)
JOIN LATERAL (
  SELECT item.canonical_key, item.language_code
  FROM wire_serving.items AS item
  WHERE item.canonical_key = candidate.value->'item'->>'itemId'
  LIMIT 1
) AS item ON TRUE
WHERE generation.expires_at > CURRENT_TIMESTAMP
  AND (generation.language = 'und' OR item.language_code = generation.language);

CREATE OR REPLACE VIEW wire_serving.finance_source_candidates
WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, candidate.ordinality AS ordinal,
  candidate.value->'item'->>'itemId' AS item_id, candidate.value AS candidate
FROM finance_generations AS generation
CROSS JOIN LATERAL jsonb_array_elements(generation.payload)
  WITH ORDINALITY AS candidate(value, ordinality)
JOIN LATERAL (
  SELECT item.canonical_key, item.language_code
  FROM wire_serving.items AS item
  WHERE item.canonical_key = candidate.value->'item'->>'itemId'
  LIMIT 1
) AS item ON TRUE
WHERE generation.expires_at > CURRENT_TIMESTAMP
  AND (generation.language = 'und' OR item.language_code = generation.language);
