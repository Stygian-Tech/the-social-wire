-- Idle projection eviction is application-configured and OFF by default.
-- Authority and the verified manifest survive eviction; missing derived rows
-- must never be interpreted as a valid all-unread generation.
ALTER TABLE appview_pds_read_state_authority
  ADD COLUMN IF NOT EXISTS projection_ready BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS last_accessed_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
CREATE INDEX IF NOT EXISTS appview_pds_read_state_idle
  ON appview_pds_read_state_authority (projection_ready, last_accessed_at, viewer_did)
  WHERE manifest_cid IS NOT NULL;

CREATE OR REPLACE FUNCTION appview_assert_pds_projection_ready(ready BOOLEAN)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF ready IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'ReadStateProjectionNotReady' USING ERRCODE = '55000';
  END IF;
  RETURN TRUE;
END $$;

CREATE OR REPLACE FUNCTION appview_pds_entry_is_read(
  viewer TEXT, subject TEXT, author TEXT, site TEXT, position_at TIMESTAMPTZ
) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN authority.manifest_cid IS NULL THEN NULL
    WHEN appview_assert_pds_projection_ready(authority.projection_ready) THEN COALESCE((
    SELECT matched.is_read FROM (
      SELECT item.sequence, item.is_read FROM appview_pds_read_state_exact item
      WHERE item.viewer_did = viewer AND item.subject_uri = subject
      UNION ALL
      SELECT rule.sequence, rule.is_read FROM appview_pds_read_state_boundaries rule
      WHERE rule.viewer_did = viewer AND rule.author_did = author
        AND (rule.scope_keys = '[]'::jsonb OR rule.scope_keys ? site)
        AND (position_at < rule.boundary_at OR (position_at = rule.boundary_at
          AND (rule.boundary_uri IS NULL OR subject COLLATE "C" <= rule.boundary_uri COLLATE "C")))
    ) matched ORDER BY matched.sequence DESC LIMIT 1
  ), FALSE) END
  FROM appview_pds_read_state_authority authority WHERE authority.viewer_did = viewer
$$;
