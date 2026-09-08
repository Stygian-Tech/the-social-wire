-- Deferred dependencies must verify the original public recommendation before
-- newly hydrated shared aliases can make the old envelope visible again.
ALTER TABLE wire_recommendation_journal
  ADD COLUMN dependency_verification_required BOOLEAN NOT NULL DEFAULT FALSE;
-- Old workers can still insert during a rolling deployment. Their newly deferred
-- rows must require proof; the new processor opts out only for fresh live intake.
ALTER TABLE wire_recommendation_journal ALTER COLUMN dependency_verification_required SET DEFAULT TRUE;
UPDATE wire_recommendation_journal SET dependency_verification_required = TRUE WHERE status = 'pending';
CREATE INDEX wire_recommendation_hydration_seed_idx
  ON wire_recommendation_journal (environment, event_time, source_generation, seq)
  WHERE status = 'pending';

CREATE TABLE wire_recommendation_dependency_recovery (
  environment TEXT NOT NULL,
  source_uri TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  seq BIGINT NOT NULL,
  expected_cid TEXT,
  subject_uri TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'leased', 'verified', 'absent', 'changed', 'inactive', 'unavailable', 'unsupported', 'superseded')),
  verified_cid TEXT,
  verified_subject_uri TEXT,
  observed_repo_rev TEXT,
  observed_at TIMESTAMPTZ,
  valid_until TIMESTAMPTZ,
  verification_token TEXT,
  staged_publication_seq BIGINT,
  staged_document_seq BIGINT,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL,
  lease_token TEXT,
  lease_expires_at TIMESTAMPTZ,
  failure_reason TEXT,
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (environment, source_uri)
);
CREATE INDEX wire_recommendation_dependency_ready_idx
  ON wire_recommendation_dependency_recovery (environment, next_attempt_at, source_uri);
CREATE SEQUENCE wire_pds_hydration_sequence;
COMMENT ON TABLE wire_recommendation_dependency_recovery IS
  'Logged current-record verification and retry controls, not fabricated source deletion events. No record bodies are copied and authoritative absence observations do not expire automatically.';
