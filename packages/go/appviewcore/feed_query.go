package appviewcore

// Shared materialized feed membership selection. All request values are bound.
const feedScopeQuery = `WITH request_limits AS (
  SELECT $1::bigint AS page_limit
), feed_definition AS (
  SELECT MAX(updated_at) AS updated_at
  FROM (
    SELECT vf.updated_at
    FROM appview_viewer_feeds vf
    WHERE $2 = FALSE
      AND vf.viewer_did = $3
      AND vf.feed_kind = $4
      AND vf.feed_id = $5
    UNION ALL
    SELECT scope.updated_at
    FROM appview_publication_scopes scope
    WHERE $2 = TRUE
      AND scope.viewer_did = $3
      AND (
        scope.publication_id = $5
        OR scope.publication_at_uri = $5
        OR scope.scope_keys ? $5
      )
  ) definitions
), matching_scope_keys AS (
  -- Feed membership and keys both reference the owning scope. Avoid rereading
  -- every viewer scope (including hundreds outside this feed) for this branch.
  SELECT keys.viewer_did,keys.publication_id,keys.author_did,keys.scope_key
  FROM appview_publication_scope_keys keys
  JOIN appview_feed_publications membership
    ON membership.viewer_did=keys.viewer_did
   AND membership.publication_id=keys.publication_id
  WHERE $2=FALSE AND keys.viewer_did=$3
   AND membership.feed_kind=$4 AND membership.feed_id=$5
  UNION
  SELECT keys.viewer_did,keys.publication_id,keys.author_did,keys.scope_key
  FROM appview_publication_scopes scope
  JOIN appview_publication_scope_keys keys
    ON keys.viewer_did=scope.viewer_did AND keys.publication_id=scope.publication_id
  WHERE $2=TRUE AND scope.viewer_did=$3
   AND (scope.publication_id=$5 OR scope.publication_at_uri=$5 OR scope.scope_keys ? $5)
)`
