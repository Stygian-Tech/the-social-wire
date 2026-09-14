-- This is a locking correctness index, not a redundant lookup index. PostgreSQL
-- locks updates to plain unique-index key columns FOR UPDATE. That keeps owner,
-- token and release changes exclusive against FOR KEY SHARE publication fences,
-- including releases from older replicas during rolling deployments. Expiry-only
-- renewal remains a compatible FOR NO KEY UPDATE operation.
--
-- Install through Database Migrator before deploying shared-fence consumers.
-- Retain this index when rolling application code back. Do not make it partial,
-- use expressions, or move authority columns into INCLUDE.
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '10s';

CREATE UNIQUE INDEX operations_role_leases_authority_key
  ON public.operations_role_leases (environment, role, owner_id, fencing_token, released_at);

COMMENT ON INDEX public.operations_role_leases_authority_key IS
  'Required for shared lease fencing: ownership and revocation updates must conflict with FOR KEY SHARE; expiry-only renewals must not. Retain on application rollback.';
