-- Bound The Wire durable inbox without weakening its checkpoint authority.
-- Actionable events never expire: they remain replayable until the worker has
-- either applied them or explicitly dead-lettered them.

ALTER TABLE wire_ingestion_inbox
  ALTER COLUMN expires_at SET DEFAULT 'infinity'::timestamptz;

CREATE TABLE IF NOT EXISTS wire_ingestion_admission (
  environment TEXT PRIMARY KEY,
  retained_rows BIGINT NOT NULL CHECK (retained_rows >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO wire_ingestion_admission (environment, retained_rows)
VALUES ('dev', 0), ('prod', 0)
ON CONFLICT (environment) DO NOTHING;

-- The fenced ingester reconciles this counter after acquiring its exclusive
-- source lease and before opening Jetstream. This avoids a migration-time scan
-- racing the prior deployment while keeping the migration lightweight.

COMMENT ON COLUMN wire_ingestion_inbox.expires_at IS
  'Terminal-row cleanup boundary. New actionable rows use infinity; cleanup must never delete pending, leased, or retry rows, including legacy finite rows.';
