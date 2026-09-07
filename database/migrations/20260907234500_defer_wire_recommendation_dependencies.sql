-- Recommendation dependencies must survive an unlogged inbox reset and must
-- not hold publication/document events behind a missing subject.
ALTER TABLE wire_ingestion_inbox DROP CONSTRAINT wire_ingestion_inbox_status;
ALTER TABLE wire_ingestion_inbox ADD CONSTRAINT wire_ingestion_inbox_status
  CHECK (status IN ('pending', 'leased', 'retry', 'applied', 'dead_letter', 'deferred', 'superseded'));

CREATE TABLE wire_recommendation_journal (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  seq BIGINT NOT NULL,
  source_host TEXT NOT NULL,
  cursor_kind TEXT NOT NULL,
  repo_did TEXT NOT NULL,
  source_uri TEXT NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
  repo_rev TEXT,
  record_cid TEXT,
  payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  event_time TIMESTAMPTZ NOT NULL,
  actor_key_hash TEXT NOT NULL,
  actor_recorded BOOLEAN NOT NULL DEFAULT FALSE,
  subject_uri TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'resolved', 'deleted', 'superseded', 'conflict', 'expired')),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL,
  failure_reason TEXT,
  canonical_key TEXT,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (environment, source_generation, seq)
);
CREATE INDEX wire_recommendation_journal_ready_idx
  ON wire_recommendation_journal (next_attempt_at, environment, source_generation, seq)
  WHERE status = 'pending';
CREATE INDEX wire_recommendation_journal_scoped_ready_idx
  ON wire_recommendation_journal (environment, source_generation, next_attempt_at, seq)
  WHERE status = 'pending';
CREATE INDEX wire_recommendation_journal_source_idx
  ON wire_recommendation_journal (environment, source_uri);
CREATE INDEX wire_recommendation_journal_resolved_idx
  ON wire_recommendation_journal (event_time, environment, source_generation, seq)
  WHERE status = 'resolved';
CREATE INDEX wire_recommendation_journal_scoped_resolved_idx
  ON wire_recommendation_journal (environment, source_generation, event_time, seq)
  WHERE status = 'resolved';
CREATE INDEX wire_recommendation_journal_backlog_idx
  ON wire_recommendation_journal (status, event_time, environment, source_generation, seq)
  WHERE status IN ('pending', 'conflict');
CREATE INDEX wire_recommendation_journal_scoped_backlog_idx
  ON wire_recommendation_journal (environment, source_generation, status, event_time, seq)
  WHERE status IN ('pending', 'conflict');

CREATE TABLE wire_recommendation_record_fences (
  environment TEXT NOT NULL,
  source_uri TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  seq BIGINT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (environment, source_uri),
  FOREIGN KEY (environment, source_generation, seq)
    REFERENCES wire_recommendation_journal (environment, source_generation, seq)
);

CREATE TABLE wire_recommendation_account_fences (
  environment TEXT NOT NULL,
  repo_did TEXT NOT NULL,
  active BOOLEAN NOT NULL,
  event_time TIMESTAMPTZ NOT NULL,
  inactive_through TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (environment, repo_did)
);

COMMENT ON TABLE wire_recommendation_journal IS
  'Logged recommendation envelopes. Pending dependencies and ambiguous versions are retained; inbox handoff is atomic. No automatic retention until replay-safe fence retention is established.';
COMMENT ON TABLE wire_recommendation_record_fences IS
  'Durable current recommendation versions, including deletion fences, preventing delayed dependency resolution from resurrecting obsolete records.';
