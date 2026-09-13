-- Opt-in disposable maintenance indexes. No corpus scan occurs during migration.
SET LOCAL lock_timeout = '5s';
CREATE UNLOGGED SEQUENCE wire_signal_rollup_revision;
CREATE UNLOGGED TABLE wire_signal_rollup_dirty (
  canonical_key text PRIMARY KEY,
  revision bigint NOT NULL DEFAULT nextval('wire_signal_rollup_revision')
);
CREATE UNLOGGED TABLE wire_signal_rollup_schedule (
  canonical_key text PRIMARY KEY,
  next_due_at timestamptz NOT NULL
);
CREATE INDEX wire_signal_rollup_schedule_due_idx
  ON wire_signal_rollup_schedule (next_due_at, canonical_key);
CREATE TABLE wire_signal_rollup_control (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  tracking_enabled boolean NOT NULL DEFAULT false,
  last_as_of timestamptz,
  postmaster_started_at timestamptz,
  relation_signature text
);
INSERT INTO wire_signal_rollup_control (singleton) VALUES (true);

CREATE FUNCTION wire_signal_rollup_mark_dirty() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- Only fields consumed by the exact aggregate invalidate it. Transport and
  -- receipt timestamp refreshes must not manufacture scheduling writes.
  IF TG_OP = 'UPDATE' THEN
    IF TG_TABLE_NAME = 'wire_article_feedback' THEN
      IF ROW(OLD.canonical_key, OLD.feedback_value, OLD.occurred_at, OLD.expires_at)
        IS NOT DISTINCT FROM ROW(NEW.canonical_key, NEW.feedback_value, NEW.occurred_at, NEW.expires_at) THEN
        RETURN NULL;
      END IF;
    ELSE
      IF ROW(OLD.canonical_key, OLD.actor_key_hash, OLD.community_key_hash, OLD.signal_kind,
             OLD.source_collection, OLD.occurred_at, OLD.expires_at)
        IS NOT DISTINCT FROM ROW(NEW.canonical_key, NEW.actor_key_hash, NEW.community_key_hash,
             NEW.signal_kind, NEW.source_collection, NEW.occurred_at, NEW.expires_at) THEN
        RETURN NULL;
      END IF;
    END IF;
  END IF;
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.canonical_key <> NEW.canonical_key) THEN
    INSERT INTO wire_signal_rollup_dirty (canonical_key) VALUES (OLD.canonical_key)
      ON CONFLICT (canonical_key) DO UPDATE SET revision = EXCLUDED.revision;
  END IF;
  IF TG_OP <> 'DELETE' THEN
    INSERT INTO wire_signal_rollup_dirty (canonical_key) VALUES (NEW.canonical_key)
      ON CONFLICT (canonical_key) DO UPDATE SET revision = EXCLUDED.revision;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER wire_signal_rollup_signal_dirty
  AFTER INSERT OR UPDATE OR DELETE ON wire_signal_events
  FOR EACH ROW EXECUTE FUNCTION wire_signal_rollup_mark_dirty();
CREATE TRIGGER wire_signal_rollup_feedback_dirty
  AFTER INSERT OR UPDATE OR DELETE ON wire_article_feedback
  FOR EACH ROW EXECUTE FUNCTION wire_signal_rollup_mark_dirty();
ALTER TABLE wire_signal_events DISABLE TRIGGER wire_signal_rollup_signal_dirty;
ALTER TABLE wire_article_feedback DISABLE TRIGGER wire_signal_rollup_feedback_dirty;

-- Run explicitly only after workload validation. Locking the sources makes the
-- tracking transition atomic with source mutations; a subsequent full refresh
-- establishes coverage. Disabling removes all per-row synchronization overhead.
CREATE FUNCTION wire_set_signal_rollup_tracking(enabled boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('wire_signal_rollups_refresh')::bigint);
  IF enabled THEN
    ALTER TABLE wire_signal_events ENABLE TRIGGER wire_signal_rollup_signal_dirty;
    ALTER TABLE wire_article_feedback ENABLE TRIGGER wire_signal_rollup_feedback_dirty;
  ELSE
    ALTER TABLE wire_signal_events DISABLE TRIGGER wire_signal_rollup_signal_dirty;
    ALTER TABLE wire_article_feedback DISABLE TRIGGER wire_signal_rollup_feedback_dirty;
  END IF;
  UPDATE wire_signal_rollup_control SET tracking_enabled = enabled, last_as_of = NULL,
    postmaster_started_at = NULL, relation_signature = NULL WHERE singleton;
END $$;

CREATE FUNCTION wire_signal_rollup_relation_signature() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT string_agg(relation.oid::text || ':' || relation.relfilenode::text,
                    ',' ORDER BY relation.oid)
  FROM pg_class relation
  WHERE relation.oid IN (
    SELECT relid FROM pg_partition_tree('wire_signal_events'::regclass)
    UNION ALL SELECT unnest(ARRAY['wire_article_feedback'::regclass,
      'wire_signal_rollups'::regclass, 'wire_signal_rollup_dirty'::regclass,
      'wire_signal_rollup_schedule'::regclass, 'wire_signal_rollup_revision'::regclass])
  )
$$;
