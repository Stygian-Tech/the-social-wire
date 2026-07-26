CREATE TABLE IF NOT EXISTS appview_jetstream_endpoints (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  host TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('active', 'standby')),
  connection_state TEXT NOT NULL DEFAULT 'unknown'
    CHECK (connection_state IN ('connected', 'disconnected', 'reconnecting', 'unknown')),
  last_connected_at TIMESTAMPTZ,
  last_disconnected_at TIMESTAMPTZ,
  last_error TEXT,
  connection_attempts INTEGER NOT NULL DEFAULT 0,
  failover_count INTEGER NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS operations_commands (
  id TEXT PRIMARY KEY,
  action TEXT NOT NULL CHECK (action IN ('reconnect_jetstream')),
  status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed')),
  requested_by_did TEXT NOT NULL,
  audit_note TEXT NOT NULL,
  claimed_by TEXT,
  failure_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_operations_commands_claim
  ON operations_commands (action, status, created_at);

CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_commands_one_active_action
  ON operations_commands (action)
  WHERE status IN ('queued', 'running');

COMMENT ON TABLE operations_commands IS
  'Audited operator commands claimed by backend workers; contains no credentials or request bodies.';
