CREATE TABLE IF NOT EXISTS operations_role_leases (
  environment TEXT NOT NULL,
  role TEXT NOT NULL,
  owner_id TEXT NOT NULL,
  fencing_token BIGINT NOT NULL,
  acquired_at TIMESTAMPTZ NOT NULL,
  lease_expires_at TIMESTAMPTZ NOT NULL,
  released_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (environment, role),
  CONSTRAINT operations_role_leases_environment_length
    CHECK (char_length(environment) BETWEEN 1 AND 32),
  CONSTRAINT operations_role_leases_role_length
    CHECK (char_length(role) BETWEEN 1 AND 128),
  CONSTRAINT operations_role_leases_owner_length
    CHECK (char_length(owner_id) BETWEEN 1 AND 255),
  CONSTRAINT operations_role_leases_fencing_token_positive
    CHECK (fencing_token > 0),
  CONSTRAINT operations_role_leases_expiry_order
    CHECK (lease_expires_at > acquired_at)
);

CREATE INDEX IF NOT EXISTS operations_role_leases_expiry_idx
  ON operations_role_leases (environment, lease_expires_at, role);

COMMENT ON TABLE operations_role_leases IS
  'Environment- and role-scoped singleton leases. Every takeover increments the fencing token so stale owners cannot renew, release, or enter fenced work.';
