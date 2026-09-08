-- Authority changes only after a complete verified PDS generation and exact
-- legacy-baseline parity. Existing read-state rows remain intact.
CREATE TABLE IF NOT EXISTS appview_pds_read_state_authority (
  viewer_did TEXT PRIMARY KEY,
  legacy_revision BIGINT NOT NULL DEFAULT 0,
  manifest JSONB,
  manifest_cid TEXT,
  last_sequence BIGINT NOT NULL DEFAULT 0,
  activated_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK ((manifest IS NULL) = (manifest_cid IS NULL))
);
CREATE TABLE IF NOT EXISTS appview_pds_read_state_exact (
  viewer_did TEXT NOT NULL REFERENCES appview_pds_read_state_authority(viewer_did),
  subject_uri TEXT NOT NULL,
  sequence BIGINT NOT NULL,
  is_read BOOLEAN NOT NULL,
  acted_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (viewer_did, subject_uri)
);
CREATE TABLE IF NOT EXISTS appview_pds_read_state_boundaries (
  viewer_did TEXT NOT NULL REFERENCES appview_pds_read_state_authority(viewer_did),
  rule_key TEXT NOT NULL,
  sequence BIGINT NOT NULL,
  is_read BOOLEAN NOT NULL,
  acted_at TIMESTAMPTZ NOT NULL,
  publication_id TEXT NOT NULL,
  author_did TEXT NOT NULL,
  scope_keys JSONB NOT NULL,
  boundary_at TIMESTAMPTZ NOT NULL,
  boundary_uri TEXT,
  PRIMARY KEY (viewer_did, sequence, rule_key)
);
CREATE INDEX IF NOT EXISTS appview_pds_read_state_boundary_match
  ON appview_pds_read_state_boundaries (viewer_did, author_did, sequence DESC);

CREATE OR REPLACE FUNCTION appview_fence_legacy_read_state() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE viewer TEXT; active BOOLEAN;
BEGIN
  viewer := CASE WHEN TG_OP = 'DELETE' THEN OLD.viewer_did ELSE NEW.viewer_did END;
  INSERT INTO appview_pds_read_state_authority(viewer_did) VALUES (viewer)
  ON CONFLICT (viewer_did) DO NOTHING;
  SELECT manifest_cid IS NOT NULL INTO active
    FROM appview_pds_read_state_authority WHERE viewer_did = viewer FOR UPDATE;
  IF active AND TG_TABLE_NAME <> 'appview_publication_scopes' THEN
    RAISE EXCEPTION 'PDS read-state authority requires a verified PDS commit'
      USING ERRCODE = '55000';
  END IF;
  IF NOT active THEN
    UPDATE appview_pds_read_state_authority
    SET legacy_revision = legacy_revision + 1, updated_at = NOW()
    WHERE viewer_did = viewer;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
DO $$
DECLARE relation TEXT;
BEGIN
  FOREACH relation IN ARRAY ARRAY['read_marks','appview_unread_overrides',
    'appview_publication_read_floors','appview_publication_scopes'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS appview_legacy_read_state_fence ON %I', relation);
    EXECUTE format('CREATE TRIGGER appview_legacy_read_state_fence BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION appview_fence_legacy_read_state()', relation);
  END LOOP;
END $$;

-- NULL means this viewer retains AppView authority. An active empty generation
-- means unread, not fallback to old watermarks. Match bytewise URI ties exactly
-- as ReadStateCore does, independent of the database locale.
CREATE OR REPLACE FUNCTION appview_pds_entry_is_read(
  viewer TEXT, subject TEXT, author TEXT, site TEXT, position_at TIMESTAMPTZ
) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN authority.manifest_cid IS NULL THEN NULL ELSE COALESCE((
    SELECT matched.is_read FROM (
      SELECT item.sequence, item.is_read FROM appview_pds_read_state_exact item
      WHERE item.viewer_did = viewer
        AND item.subject_uri = subject
      UNION ALL
      SELECT rule.sequence, rule.is_read FROM appview_pds_read_state_boundaries rule
      WHERE rule.viewer_did = viewer
        AND rule.author_did = author
        AND (rule.scope_keys = '[]'::jsonb OR rule.scope_keys ? site)
        AND (position_at < rule.boundary_at OR (position_at = rule.boundary_at
          AND (rule.boundary_uri IS NULL OR subject COLLATE "C" <= rule.boundary_uri COLLATE "C")))
    ) matched ORDER BY matched.sequence DESC LIMIT 1
  ), FALSE) END
  FROM (SELECT (SELECT manifest_cid FROM appview_pds_read_state_authority
    WHERE viewer_did = viewer) AS manifest_cid) authority
$$;

-- Keep the legacy joins in the caller so PostgreSQL can retain hash/merge plans.
-- This scalar table function inlines; PDS evaluation is lazy for active viewers.
CREATE OR REPLACE FUNCTION appview_effective_entry_read_state(
  viewer TEXT, subject TEXT, author TEXT, site TEXT, position_at TIMESTAMPTZ,
  legacy_read_uri TEXT, legacy_unread_uri TEXT
) RETURNS TABLE(read_uri TEXT, unread_uri TEXT) LANGUAGE sql STABLE AS $$
  SELECT
    CASE WHEN (SELECT manifest_cid FROM appview_pds_read_state_authority WHERE viewer_did = viewer) IS NULL
      THEN legacy_read_uri
      WHEN appview_pds_entry_is_read(viewer, subject, author, site, position_at) THEN subject END,
    CASE WHEN (SELECT manifest_cid FROM appview_pds_read_state_authority WHERE viewer_did = viewer) IS NULL
      THEN legacy_unread_uri
      WHEN NOT appview_pds_entry_is_read(viewer, subject, author, site, position_at) THEN subject END
$$;
