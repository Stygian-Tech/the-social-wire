-- The original definition called appview_pds_entry_is_read separately for the read
-- and unread columns, doubling the exact and boundary lookups for every feed entry.
-- OFFSET 0 keeps PostgreSQL from pulling the subquery up and re-expanding the call
-- into both columns. Results are unchanged: legacy viewers still pass through their
-- legacy URIs, and a PDS viewer yields exactly one of read_uri or unread_uri.
CREATE OR REPLACE FUNCTION appview_effective_entry_read_state(
  viewer TEXT, subject TEXT, author TEXT, site TEXT, position_at TIMESTAMPTZ,
  legacy_read_uri TEXT, legacy_unread_uri TEXT
) RETURNS TABLE(read_uri TEXT, unread_uri TEXT) LANGUAGE sql STABLE AS $$
  SELECT
    CASE WHEN authority.manifest_cid IS NULL THEN legacy_read_uri
      WHEN pds.is_read THEN subject END,
    CASE WHEN authority.manifest_cid IS NULL THEN legacy_unread_uri
      WHEN NOT pds.is_read THEN subject END
  FROM (SELECT (SELECT manifest_cid FROM appview_pds_read_state_authority
    WHERE viewer_did = viewer) AS manifest_cid) authority
  LEFT JOIN LATERAL (
    SELECT appview_pds_entry_is_read(viewer, subject, author, site, position_at) AS is_read
    WHERE authority.manifest_cid IS NOT NULL
    OFFSET 0
  ) pds ON TRUE
$$;
