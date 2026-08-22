\set ON_ERROR_STOP on

DO $$
DECLARE
  contract_version INTEGER;
  forbidden_columns INTEGER;
BEGIN
  SELECT contract.contract_version
  INTO contract_version
  FROM wire_serving.contract AS contract;
  IF contract_version <> 2 THEN
    RAISE EXCEPTION 'unexpected wire_serving contract version: %', contract_version;
  END IF;

  SELECT COUNT(*)
  INTO forbidden_columns
  FROM information_schema.columns
  WHERE table_schema = 'wire_serving'
    AND column_name IN (
      'score', 'diversity_metadata', 'diagnostics', 'candidate_count', 'ranked_count',
      'source_confidence', 'label_count', 'target_count', 'actor_key_hash',
      'community_key_hash', 'speaker_key_hash', 'story_count', 'speaker_count',
      'best_story_rank', 'latest_mention_at', 'payload'
    );
  IF forbidden_columns <> 0 THEN
    RAISE EXCEPTION 'wire_serving exposes forbidden internal columns';
  END IF;
END
$$;

BEGIN;
CREATE ROLE wire_corpus_edge_contract_test NOLOGIN;
GRANT USAGE ON SCHEMA wire_serving TO wire_corpus_edge_contract_test;
GRANT SELECT ON ALL TABLES IN SCHEMA wire_serving TO wire_corpus_edge_contract_test;
SET LOCAL ROLE wire_corpus_edge_contract_test;

SELECT contract_version FROM wire_serving.contract;
SELECT has_current_snapshot, oldest_successful_at FROM wire_serving.label_health;
SELECT generation_id, language_bucket, generated_at, expires_at
FROM wire_serving.feed_state LIMIT 1;
SELECT position, canonical_key, reason_codes
FROM wire_serving.ranked_items LIMIT 1;
SELECT canonical_key, canonical_url, author_key
FROM wire_serving.items LIMIT 1;
SELECT generation_id, algorithm_version, language_bucket, continuation_ordinal
FROM wire_serving.edition_generations LIMIT 1;
SELECT generation_id, module_key, module_kind, publication_key
FROM wire_serving.edition_modules LIMIT 1;
SELECT generation_id, module_key, module_position, canonical_key, publication_key
FROM wire_serving.edition_module_items LIMIT 1;
SELECT generation_id, position, subject_did, handle
FROM wire_serving.edition_talked_accounts LIMIT 1;

DO $$
BEGIN
  BEGIN
    PERFORM canonical_key FROM public.wire_items LIMIT 1;
    RAISE EXCEPTION 'read-only corpus role unexpectedly read public.wire_items';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    EXECUTE 'DELETE FROM wire_serving.items WHERE FALSE';
    RAISE EXCEPTION 'read-only corpus role unexpectedly mutated a serving view';
  EXCEPTION WHEN insufficient_privilege OR object_not_in_prerequisite_state THEN
    NULL;
  END;
END
$$;

ROLLBACK;
