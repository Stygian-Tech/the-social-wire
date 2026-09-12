-- Disposable scheduling projection. Tracking and readers stay off until measured validation.
SET LOCAL lock_timeout = '5s';
CREATE TABLE wire_metadata_priority_work (
  canonical_key text PRIMARY KEY,
  item_present boolean NOT NULL DEFAULT false,
  cache_present boolean NOT NULL DEFAULT false,
  language_code text,
  eligible boolean,
  expires_at timestamptz,
  target_kind text,
  commercial_class text,
  source_confidence double precision,
  last_signal_at timestamptz,
  language_checked_at timestamptz,
  source text,
  status text,
  retry_after timestamptz,
  fresh_until timestamptz
);
CREATE INDEX wire_metadata_priority_work_tombstones_idx ON wire_metadata_priority_work (canonical_key)
  WHERE NOT item_present AND NOT cache_present;
CREATE TABLE wire_metadata_schedule_control (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  tracking_enabled boolean NOT NULL DEFAULT false,
  read_ready boolean NOT NULL DEFAULT false,
  item_cursor text NOT NULL DEFAULT '', cache_cursor text NOT NULL DEFAULT '',
  item_pass_complete boolean NOT NULL DEFAULT false,
  cache_pass_complete boolean NOT NULL DEFAULT false,
  tracking_postmaster_started_at timestamptz, validated_postmaster_started_at timestamptz,
  validated_at timestamptz, validation_mismatches bigint
);
INSERT INTO wire_metadata_schedule_control (singleton) VALUES (true);

-- Each source owns only its columns. Deferred delivery keeps projection locks
-- after base writes; separate column groups avoid stale joined-snapshot overwrites.
CREATE FUNCTION wire_metadata_schedule_item_changed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND ROW(OLD.canonical_key, OLD.language_code, OLD.eligible, OLD.expires_at, OLD.target_kind, OLD.commercial_class, OLD.source_confidence, OLD.last_signal_at)
      IS NOT DISTINCT FROM ROW(NEW.canonical_key, NEW.language_code, NEW.eligible, NEW.expires_at, NEW.target_kind, NEW.commercial_class, NEW.source_confidence, NEW.last_signal_at) THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.canonical_key <> NEW.canonical_key) THEN
    INSERT INTO wire_metadata_priority_work (canonical_key, item_present, language_code, eligible, expires_at, target_kind, commercial_class, source_confidence, last_signal_at)
      VALUES (OLD.canonical_key, false, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
      ON CONFLICT (canonical_key) DO UPDATE SET
        item_present = EXCLUDED.item_present, language_code = EXCLUDED.language_code, eligible = EXCLUDED.eligible, expires_at = EXCLUDED.expires_at, target_kind = EXCLUDED.target_kind, commercial_class = EXCLUDED.commercial_class, source_confidence = EXCLUDED.source_confidence, last_signal_at = EXCLUDED.last_signal_at
      WHERE ROW(wire_metadata_priority_work.item_present, wire_metadata_priority_work.language_code, wire_metadata_priority_work.eligible, wire_metadata_priority_work.expires_at, wire_metadata_priority_work.target_kind, wire_metadata_priority_work.commercial_class, wire_metadata_priority_work.source_confidence, wire_metadata_priority_work.last_signal_at)
        IS DISTINCT FROM ROW(EXCLUDED.item_present, EXCLUDED.language_code, EXCLUDED.eligible, EXCLUDED.expires_at, EXCLUDED.target_kind, EXCLUDED.commercial_class, EXCLUDED.source_confidence, EXCLUDED.last_signal_at);
  END IF;
  IF TG_OP <> 'DELETE' THEN
    INSERT INTO wire_metadata_priority_work (canonical_key, item_present, language_code, eligible, expires_at, target_kind, commercial_class, source_confidence, last_signal_at)
      VALUES (NEW.canonical_key, true, NEW.language_code, NEW.eligible, NEW.expires_at, NEW.target_kind, NEW.commercial_class, NEW.source_confidence, NEW.last_signal_at)
      ON CONFLICT (canonical_key) DO UPDATE SET
        item_present = EXCLUDED.item_present, language_code = EXCLUDED.language_code, eligible = EXCLUDED.eligible, expires_at = EXCLUDED.expires_at, target_kind = EXCLUDED.target_kind, commercial_class = EXCLUDED.commercial_class, source_confidence = EXCLUDED.source_confidence, last_signal_at = EXCLUDED.last_signal_at
      WHERE ROW(wire_metadata_priority_work.item_present, wire_metadata_priority_work.language_code, wire_metadata_priority_work.eligible, wire_metadata_priority_work.expires_at, wire_metadata_priority_work.target_kind, wire_metadata_priority_work.commercial_class, wire_metadata_priority_work.source_confidence, wire_metadata_priority_work.last_signal_at)
        IS DISTINCT FROM ROW(EXCLUDED.item_present, EXCLUDED.language_code, EXCLUDED.eligible, EXCLUDED.expires_at, EXCLUDED.target_kind, EXCLUDED.commercial_class, EXCLUDED.source_confidence, EXCLUDED.last_signal_at);
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER wire_metadata_schedule_item_sync
  AFTER INSERT OR UPDATE OR DELETE ON wire_items
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
  EXECUTE FUNCTION wire_metadata_schedule_item_changed();
ALTER TABLE wire_items DISABLE TRIGGER wire_metadata_schedule_item_sync;

-- Each source owns only its columns. Deferred delivery keeps projection locks
-- after base writes; separate column groups avoid stale joined-snapshot overwrites.
CREATE FUNCTION wire_metadata_schedule_cache_changed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND ROW(OLD.canonical_key, OLD.language_checked_at, OLD.source, OLD.status, OLD.retry_after, OLD.fresh_until)
      IS NOT DISTINCT FROM ROW(NEW.canonical_key, NEW.language_checked_at, NEW.source, NEW.status, NEW.retry_after, NEW.fresh_until) THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.canonical_key <> NEW.canonical_key) THEN
    INSERT INTO wire_metadata_priority_work (canonical_key, cache_present, language_checked_at, source, status, retry_after, fresh_until)
      VALUES (OLD.canonical_key, false, NULL, NULL, NULL, NULL, NULL)
      ON CONFLICT (canonical_key) DO UPDATE SET
        cache_present = EXCLUDED.cache_present, language_checked_at = EXCLUDED.language_checked_at, source = EXCLUDED.source, status = EXCLUDED.status, retry_after = EXCLUDED.retry_after, fresh_until = EXCLUDED.fresh_until
      WHERE ROW(wire_metadata_priority_work.cache_present, wire_metadata_priority_work.language_checked_at, wire_metadata_priority_work.source, wire_metadata_priority_work.status, wire_metadata_priority_work.retry_after, wire_metadata_priority_work.fresh_until)
        IS DISTINCT FROM ROW(EXCLUDED.cache_present, EXCLUDED.language_checked_at, EXCLUDED.source, EXCLUDED.status, EXCLUDED.retry_after, EXCLUDED.fresh_until);
  END IF;
  IF TG_OP <> 'DELETE' THEN
    INSERT INTO wire_metadata_priority_work (canonical_key, cache_present, language_checked_at, source, status, retry_after, fresh_until)
      VALUES (NEW.canonical_key, true, NEW.language_checked_at, NEW.source, NEW.status, NEW.retry_after, NEW.fresh_until)
      ON CONFLICT (canonical_key) DO UPDATE SET
        cache_present = EXCLUDED.cache_present, language_checked_at = EXCLUDED.language_checked_at, source = EXCLUDED.source, status = EXCLUDED.status, retry_after = EXCLUDED.retry_after, fresh_until = EXCLUDED.fresh_until
      WHERE ROW(wire_metadata_priority_work.cache_present, wire_metadata_priority_work.language_checked_at, wire_metadata_priority_work.source, wire_metadata_priority_work.status, wire_metadata_priority_work.retry_after, wire_metadata_priority_work.fresh_until)
        IS DISTINCT FROM ROW(EXCLUDED.cache_present, EXCLUDED.language_checked_at, EXCLUDED.source, EXCLUDED.status, EXCLUDED.retry_after, EXCLUDED.fresh_until);
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER wire_metadata_schedule_cache_sync
  AFTER INSERT OR UPDATE OR DELETE ON wire_link_metadata_cache
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
  EXECUTE FUNCTION wire_metadata_schedule_cache_changed();
ALTER TABLE wire_link_metadata_cache DISABLE TRIGGER wire_metadata_schedule_cache_sync;

-- TRUNCATE does not fire row triggers. Invalidate coverage immediately, then
-- explicit maintenance starts a new projection epoch and backfills both sources.
CREATE FUNCTION wire_metadata_schedule_source_truncated() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE wire_metadata_schedule_control SET read_ready = false,
    tracking_postmaster_started_at = NULL, validated_postmaster_started_at = NULL
    WHERE singleton;
  RETURN NULL;
END $$;
CREATE TRIGGER wire_metadata_schedule_item_truncated AFTER TRUNCATE ON wire_items
  FOR EACH STATEMENT EXECUTE FUNCTION wire_metadata_schedule_source_truncated();
CREATE TRIGGER wire_metadata_schedule_cache_truncated AFTER TRUNCATE ON wire_link_metadata_cache
  FOR EACH STATEMENT EXECUTE FUNCTION wire_metadata_schedule_source_truncated();
ALTER TABLE wire_items DISABLE TRIGGER wire_metadata_schedule_item_truncated;
ALTER TABLE wire_link_metadata_cache DISABLE TRIGGER wire_metadata_schedule_cache_truncated;

-- This function is the sole supported tracking toggle. Source write locks ensure
-- no writer crosses a reset, and reactivation cannot reuse a stale disabled epoch.
CREATE FUNCTION wire_metadata_schedule_set_tracking(enabled boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  LOCK TABLE wire_items, wire_link_metadata_cache IN SHARE ROW EXCLUSIVE MODE;
  ALTER TABLE wire_items DISABLE TRIGGER wire_metadata_schedule_item_sync;
  ALTER TABLE wire_items DISABLE TRIGGER wire_metadata_schedule_item_truncated;
  ALTER TABLE wire_link_metadata_cache DISABLE TRIGGER wire_metadata_schedule_cache_sync;
  ALTER TABLE wire_link_metadata_cache DISABLE TRIGGER wire_metadata_schedule_cache_truncated;
  UPDATE wire_metadata_schedule_control SET tracking_enabled = false, read_ready = false,
    item_cursor = '', cache_cursor = '', item_pass_complete = false, cache_pass_complete = false,
    tracking_postmaster_started_at = NULL, validated_postmaster_started_at = NULL,
    validated_at = NULL, validation_mismatches = NULL WHERE singleton;
  IF enabled THEN
    TRUNCATE wire_metadata_priority_work;
    ALTER TABLE wire_items ENABLE TRIGGER wire_metadata_schedule_item_sync;
    ALTER TABLE wire_items ENABLE TRIGGER wire_metadata_schedule_item_truncated;
    ALTER TABLE wire_link_metadata_cache ENABLE TRIGGER wire_metadata_schedule_cache_sync;
    ALTER TABLE wire_link_metadata_cache ENABLE TRIGGER wire_metadata_schedule_cache_truncated;
    UPDATE wire_metadata_schedule_control SET tracking_enabled = true,
      tracking_postmaster_started_at = pg_postmaster_start_time() WHERE singleton;
  END IF;
END $$;
COMMENT ON TABLE wire_metadata_priority_work IS
  'Disposable owned-field scheduling projection; both presence flags required. No FK so concurrent first-source writes merge safely.';

-- Logged scheduling state must never survive an unlogged-source crash as trusted
-- readiness. Only the explicitly enabled maintenance lane can start a new epoch.
CREATE FUNCTION wire_metadata_schedule_reset_after_restart() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM wire_metadata_schedule_control
    WHERE singleton AND tracking_enabled
      AND tracking_postmaster_started_at IS DISTINCT FROM pg_postmaster_start_time()) THEN
    LOCK TABLE wire_items, wire_link_metadata_cache IN SHARE ROW EXCLUSIVE MODE;
    IF EXISTS (SELECT 1 FROM wire_metadata_schedule_control
      WHERE singleton AND tracking_enabled
        AND tracking_postmaster_started_at IS DISTINCT FROM pg_postmaster_start_time()) THEN
      PERFORM wire_metadata_schedule_set_tracking(true);
    END IF;
  END IF;
END $$;
