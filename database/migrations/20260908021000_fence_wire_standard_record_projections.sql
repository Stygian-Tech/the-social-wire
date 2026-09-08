-- PDS observations and live standard.site mutations share a compact durable
-- version fence. Tombstones must outlive disposable inbox rows and projections.
-- No document bodies are copied; authoritative records remain on the PDS.
CREATE TABLE wire_standard_record_fences (
  environment TEXT NOT NULL,
  source_uri TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  seq BIGINT NOT NULL,
  source_host TEXT NOT NULL,
  cursor_kind TEXT NOT NULL,
  event_kind TEXT NOT NULL CHECK (event_kind IN ('commit', 'snapshot')),
  operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
  repo_rev TEXT,
  observed_repo_rev TEXT,
  record_cid TEXT,
  event_time TIMESTAMPTZ NOT NULL,
  activity_recorded BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (environment, source_uri)
);
