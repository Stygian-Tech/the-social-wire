-- Extend existing granted views rather than granting the Corpus Edge access to
-- recovery jobs, source identities or raw ingestion state.
CREATE OR REPLACE VIEW wire_serving.generations AS
SELECT generation_id, language_bucket, status, generated_at, expires_at,
  (SELECT recovering FROM wire_publication_recovery_health) AS recovering
FROM wire_rank_generations
WHERE feed_key = 'wire' AND status IN ('committed', 'superseded');

CREATE OR REPLACE VIEW wire_serving.feed_state AS
SELECT state.language_bucket, generation.generation_id, generation.generated_at,
  generation.expires_at,
  (SELECT recovering FROM wire_publication_recovery_health) AS recovering
FROM wire_feed_state AS state
JOIN wire_rank_generations AS generation ON generation.generation_id = state.active_generation_id
WHERE state.feed_key = 'wire' AND generation.status = 'committed';
