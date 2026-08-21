-- socialwire:transaction=off

-- This migration is intentionally an offline maintenance operation. Stop The
-- Wire worker and every producer before applying it: the non-concurrent builds
-- block writes, but dropping the old wide index first avoids requiring enough
-- disk for two full backlog-sized indexes at once.

SET lock_timeout = '5s';
SET maintenance_work_mem = '1GB';

DROP INDEX IF EXISTS public.wire_ingestion_inbox_claimable_global_v2_idx;
DROP INDEX IF EXISTS public.wire_ingestion_inbox_claim_idx;

CREATE INDEX IF NOT EXISTS wire_ingestion_inbox_pending_retry_ready_idx
ON public.wire_ingestion_inbox (next_attempt_at, seq)
WHERE status IN ('pending', 'retry');

CREATE INDEX IF NOT EXISTS wire_ingestion_inbox_expired_lease_idx
ON public.wire_ingestion_inbox (lease_expires_at, seq)
WHERE status = 'leased';

RESET maintenance_work_mem;
RESET lock_timeout;
