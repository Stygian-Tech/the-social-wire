-- Resolve only the newest matching boundary before comparing it with the exact
-- action. The existing viewer/author/descending-sequence index can stop at the
-- first matching rule instead of collecting and sorting the viewer's history.
-- PDS authority and the fail-closed projection readiness guard remain unchanged.
CREATE OR REPLACE FUNCTION appview_pds_entry_is_read(
  viewer TEXT, subject TEXT, author TEXT, site TEXT, position_at TIMESTAMPTZ
) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN authority.manifest_cid IS NULL THEN NULL
    WHEN appview_assert_pds_projection_ready(authority.projection_ready) THEN COALESCE((
    SELECT matched.is_read FROM (
      SELECT item.sequence, item.is_read FROM appview_pds_read_state_exact item
      WHERE item.viewer_did = viewer AND item.subject_uri = subject
      UNION ALL
      (SELECT rule.sequence, rule.is_read FROM appview_pds_read_state_boundaries rule
      WHERE rule.viewer_did = viewer AND rule.author_did = author
        AND (rule.scope_keys = '[]'::jsonb OR rule.scope_keys ? site)
        AND (position_at < rule.boundary_at OR (position_at = rule.boundary_at
          AND (rule.boundary_uri IS NULL OR subject COLLATE "C" <= rule.boundary_uri COLLATE "C")))
      ORDER BY rule.sequence DESC LIMIT 1)
    ) matched ORDER BY matched.sequence DESC LIMIT 1
  ), FALSE) END
  FROM appview_pds_read_state_authority authority WHERE authority.viewer_did = viewer
$$;
