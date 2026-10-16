-- Keep live intake independent of bounded historical recovery. Every job retains
-- the canonical worker inbox generation and the parent lane's replay allowance.
CREATE TABLE IF NOT EXISTS ingestion_recovery_controllers (
 environment TEXT NOT NULL,
 source_generation TEXT NOT NULL,
 source_host TEXT NOT NULL,
 stream_nsid TEXT NOT NULL,
 filter_fingerprint TEXT NOT NULL,
 cursor_kind TEXT NOT NULL,
 last_live_seq BIGINT CHECK(last_live_seq >= 0),
 gap_after_seq BIGINT CHECK(gap_after_seq >= 0),
 incident_bytes_downloaded BIGINT NOT NULL DEFAULT 0 CHECK(incident_bytes_downloaded >= 0),
 status TEXT NOT NULL DEFAULT 'healthy' CHECK(status IN('healthy','gap_pending','recovering','paused_budget','expired','degraded','blocked_discontinuity')),
 last_error TEXT,
 canary_expires_at TIMESTAMPTZ,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 PRIMARY KEY(environment,source_generation)
);
CREATE TABLE IF NOT EXISTS ingestion_recovery_jobs (
 environment TEXT NOT NULL,
 source_generation TEXT NOT NULL,
 id TEXT NOT NULL,
 source_host TEXT NOT NULL,
 stream_nsid TEXT NOT NULL,
 filter_fingerprint TEXT NOT NULL,
 cursor_kind TEXT NOT NULL,
 after_seq BIGINT NOT NULL CHECK(after_seq >= 0),
 before_seq BIGINT NOT NULL CHECK(before_seq > after_seq),
 last_staged_seq BIGINT,
 sealed_seq BIGINT NOT NULL DEFAULT 0,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN('pending','replaying','paused_daily','paused_budget','expired','blocked_discontinuity','complete')),
 lease_owner TEXT,
 fencing_token BIGINT,
 retry_count INTEGER NOT NULL DEFAULT 0,
 range_resume_count INTEGER NOT NULL DEFAULT 0,
 etag TEXT,
 last_error TEXT,
 expires_at TIMESTAMPTZ,
 last_progress_at TIMESTAMPTZ,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 PRIMARY KEY(environment,source_generation,id),
 UNIQUE(environment,source_generation,after_seq,before_seq),
 FOREIGN KEY(environment,source_generation) REFERENCES ingestion_recovery_controllers(environment,source_generation),
 CHECK(last_staged_seq IS NULL OR last_staged_seq > after_seq AND last_staged_seq <= before_seq)
);
CREATE INDEX IF NOT EXISTS ingestion_recovery_jobs_pending_idx ON ingestion_recovery_jobs(environment,source_generation,created_at) WHERE status <> 'complete';
CREATE TABLE IF NOT EXISTS ingestion_poison_records (
 environment TEXT NOT NULL,
 source_generation TEXT NOT NULL,
 seq BIGINT NOT NULL CHECK(seq > 0),
 source_host TEXT NOT NULL,
 repo_did TEXT NOT NULL,
 collection TEXT,
 record_key TEXT,
 record_cid TEXT,
 payload_sha256 TEXT NOT NULL,
 raw_payload BYTEA,
 reason TEXT NOT NULL CHECK(OCTET_LENGTH(reason)<=512),
 status TEXT NOT NULL DEFAULT 'quarantined' CHECK(status IN('quarantined','repaired','expired')),
 first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '7 days',
 updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 PRIMARY KEY(environment,source_generation,seq)
);
CREATE INDEX IF NOT EXISTS ingestion_poison_records_unresolved_idx ON ingestion_poison_records(environment,source_generation,seq) WHERE status <> 'repaired';
CREATE OR REPLACE FUNCTION preserve_ingestion_recovery_identity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF ROW(NEW.environment,NEW.source_generation,NEW.id,NEW.source_host,NEW.stream_nsid,NEW.filter_fingerprint,NEW.cursor_kind,NEW.after_seq,NEW.before_seq,NEW.expires_at)
    IS DISTINCT FROM ROW(OLD.environment,OLD.source_generation,OLD.id,OLD.source_host,OLD.stream_nsid,OLD.filter_fingerprint,OLD.cursor_kind,OLD.after_seq,OLD.before_seq,OLD.expires_at) THEN
  RAISE EXCEPTION 'ingestion recovery identity and range are immutable';
 END IF;
 IF OLD.status='complete' AND NEW.status<>'complete' THEN
  RAISE EXCEPTION 'completed ingestion recovery cannot be reopened';
 END IF;
 RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS ingestion_recovery_identity ON ingestion_recovery_jobs;
CREATE TRIGGER ingestion_recovery_identity BEFORE UPDATE ON ingestion_recovery_jobs FOR EACH ROW EXECUTE FUNCTION preserve_ingestion_recovery_identity();
