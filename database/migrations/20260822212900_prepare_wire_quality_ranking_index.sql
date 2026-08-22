-- socialwire:transaction=off
-- Build the quality-ranking support index without blocking the recurring
-- wire_signal_rollups rebuild. The following migration uses the same index
-- name, so its transactional CREATE INDEX IF NOT EXISTS becomes a no-op.

SET lock_timeout = '5s';
SET statement_timeout = '30min';

CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_signal_rollups_high_intent_rank_idx
  ON wire_signal_rollups (shares_24h DESC, recommendations_24h DESC, canonical_key);

RESET statement_timeout;
RESET lock_timeout;
