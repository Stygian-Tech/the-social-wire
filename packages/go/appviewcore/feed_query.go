package appviewcore

// The two query plans preserve the deployed AppView page-first hydration and
// read-state evaluation. Only fixed SQL grammar is formatted; values are bound.
const feedSelectionAll = `, ranked_content AS (
  SELECT content.*,
    ROW_NUMBER() OVER (
      PARTITION BY content.article_key
      ORDER BY content.created_at DESC, content.uri DESC
    ) AS duplicate_rank
  FROM matched_content content
), selected_content AS MATERIALIZED (
  SELECT * FROM ranked_content
  WHERE duplicate_rank = 1
  ORDER BY created_at DESC, uri DESC
  LIMIT (SELECT page_limit FROM request_limits)
)`
const feedQuery = `WITH request_limits AS (
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
  SELECT DISTINCT
    keys.viewer_did,
    keys.publication_id,
    keys.author_did,
    keys.scope_key
  FROM appview_publication_scopes scope
  JOIN appview_publication_scope_keys keys
    ON keys.viewer_did = scope.viewer_did
   AND keys.publication_id = scope.publication_id
  LEFT JOIN appview_feed_publications membership
    ON membership.viewer_did = scope.viewer_did
   AND membership.publication_id = scope.publication_id
   AND membership.feed_kind = $4
   AND membership.feed_id = $5
  WHERE scope.viewer_did = $3
    AND (
      ($2 = FALSE AND membership.publication_id IS NOT NULL)
      OR (
        $2 = TRUE
        AND (
          scope.publication_id = $5
          OR scope.publication_at_uri = $5
          OR scope.scope_keys ? $5
        )
      )
    )
), matched_content AS (
  SELECT
    scope.viewer_did,
    scope.publication_id,
    ci.uri,
    COALESCE(NULLIF(ci.render_json->>'articleUrl', ''), ci.uri) AS article_key,
    ci.created_at,
    ci.author_did,
    ci.publication_site
  FROM matching_scope_keys scope
  JOIN content_items ci
    ON ci.author_did = scope.author_did
   AND ci.publication_site = scope.scope_key
  WHERE scope.scope_key <> ''
    AND ci.expires_at > $6
    AND (
      $7 = FALSE
      OR ci.created_at < $8
      OR (ci.created_at = $8 AND ci.uri < $9)
    )
  UNION ALL
  SELECT
    scope.viewer_did,
    scope.publication_id,
    ci.uri,
    COALESCE(NULLIF(ci.render_json->>'articleUrl', ''), ci.uri) AS article_key,
    ci.created_at,
    ci.author_did,
    ci.publication_site
  FROM matching_scope_keys scope
  JOIN content_items ci ON ci.author_did = scope.author_did
  WHERE scope.scope_key = ''
    AND ci.expires_at > $6
    AND (
      $7 = FALSE
      OR ci.created_at < $8
      OR (ci.created_at = $8 AND ci.uri < $9)
    )
)
%s
, candidates AS (
  SELECT
    content.uri,
    content.created_at,
    content.publication_id,
    content.author_did,
    content.publication_site,
    -- Carry flags rather than URIs and floor bounds so the deduplication sort stays narrow.
    rm.subject_uri IS NOT NULL AS legacy_read,
    uo.subject_uri IS NOT NULL AS legacy_unread,
    CASE
      WHEN floor.read_floor_at IS NULL THEN FALSE
      WHEN content.created_at < floor.read_floor_at THEN TRUE
      WHEN content.created_at = floor.read_floor_at
        AND (floor.read_floor_uri IS NULL OR content.uri <= floor.read_floor_uri) THEN TRUE
      ELSE FALSE
    END AS floor_read,
    %s AS duplicate_rank
  FROM %s content
  LEFT JOIN appview_publication_read_floors floor
    ON floor.viewer_did = content.viewer_did
   AND floor.publication_id = content.publication_id
  LEFT JOIN read_marks rm ON rm.viewer_did = $3 AND rm.subject_uri = content.uri
  LEFT JOIN appview_unread_overrides uo ON uo.viewer_did = $3 AND uo.subject_uri = content.uri
), ordered_candidates AS (
  -- Preserve a newest-first stream through read-state resolution. Without this
  -- boundary the final sort evaluates PDS state for the entire matching history
  -- before LIMIT can stop, even when the first few entries fill the requested page.
  -- OFFSET 0 prevents pull-up without capping sparse read/unread searches.
  SELECT * FROM candidates
  WHERE duplicate_rank = 1
  ORDER BY created_at DESC, uri DESC
  OFFSET 0
), resolved AS (
  -- Keep the set-based legacy joins before deduplication, but resolve authoritative
  -- state only as the ordered stream is consumed by the filtered page.
  SELECT
    candidate.uri,
    candidate.created_at,
    candidate.publication_id,
    CASE
      WHEN read_state.unread_uri IS NOT NULL THEN FALSE
      WHEN read_state.read_uri IS NOT NULL THEN TRUE
      ELSE candidate.floor_read
    END AS is_read
  FROM ordered_candidates candidate
  LEFT JOIN LATERAL appview_effective_entry_read_state($3, candidate.uri,
    candidate.author_did, candidate.publication_site, candidate.created_at,
    CASE WHEN candidate.legacy_read THEN candidate.uri END,
    CASE WHEN candidate.legacy_unread THEN candidate.uri END) read_state ON TRUE
), page AS (
  SELECT uri, created_at, publication_id, is_read
  FROM resolved
  WHERE (
      $10
      OR ($11 AND is_read = FALSE)
      OR ($12 AND is_read = TRUE)
    )
  ORDER BY created_at DESC, uri DESC
  LIMIT $1
)
SELECT
  definition.updated_at,
  page.uri,
  rendered.render_json::text,
  page.created_at,
  page.publication_id,
  page.is_read
FROM feed_definition definition
LEFT JOIN LATERAL (
  SELECT * FROM page ORDER BY created_at DESC, uri DESC
) page ON TRUE
LEFT JOIN content_items rendered ON rendered.uri = page.uri
WHERE definition.updated_at IS NOT NULL
ORDER BY page.created_at DESC NULLS LAST, page.uri DESC NULLS LAST`
