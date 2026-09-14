-- A job is registered only when the unlogged inbox epoch is lost. Exact logged
-- publication activity can restore a usable baseline while archive replay
-- independently rebuilds the rest of the signal window.
CREATE TABLE wire_publication_signal_recovery_jobs (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  inbox_initialized_at TIMESTAMPTZ NOT NULL,
  maximum_source_seq BIGINT NOT NULL,
  after_event_time TIMESTAMPTZ NOT NULL DEFAULT 'epoch',
  after_source_uri TEXT NOT NULL DEFAULT '',
  completed_at TIMESTAMPTZ,
  replay_completed_at TIMESTAMPTZ,
  PRIMARY KEY (environment, source_generation, inbox_initialized_at)
);
CREATE INDEX wire_publication_signal_recovery_pending_idx
  ON wire_publication_signal_recovery_jobs (environment, source_generation)
  WHERE completed_at IS NULL;
CREATE INDEX wire_standard_record_fences_recovery_idx
  ON wire_standard_record_fences (environment, source_generation, event_time, source_uri)
  WHERE activity_recorded AND operation <> 'delete';

CREATE VIEW wire_publication_recovery_health AS
SELECT EXISTS (
  SELECT 1 FROM (
    SELECT DISTINCT ON (environment, source_generation) replay_completed_at
    FROM wire_publication_signal_recovery_jobs
    ORDER BY environment, source_generation, inbox_initialized_at DESC
  ) latest WHERE replay_completed_at IS NULL
) AS recovering;
