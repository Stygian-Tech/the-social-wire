package appviewcore

// A global batch is contained in the newest batch from every scope. The inner
// limits bound history reads, while the outer limit supplies a resumable merge.
// Read filtering and article deduplication happen after this boundary, so sparse
// filters and long duplicate runs can continue without losing older entries.
const feedBatchQuery = feedScopeQuery + `,
raw_candidates AS (
 SELECT scope.*, ci.uri,ci.created_at,ci.publication_site
 FROM matching_scope_keys scope
 CROSS JOIN LATERAL (
  SELECT ci.uri,ci.created_at,ci.publication_site FROM content_items ci
  WHERE ci.author_did=scope.author_did AND ci.publication_site=scope.scope_key
   AND ci.expires_at>$6
   AND (NOT $7 OR (ci.created_at,ci.uri)<($8,$9)
    OR ($11 AND (ci.created_at,ci.uri)=($8,$9) AND scope.publication_id<$10))
  ORDER BY ci.created_at DESC,ci.uri DESC LIMIT $1
 ) ci
 WHERE scope.scope_key<>''
 UNION ALL
 SELECT scope.*,ci.uri,ci.created_at,ci.publication_site
 FROM matching_scope_keys scope
 CROSS JOIN LATERAL (
  SELECT ci.uri,ci.created_at,ci.publication_site FROM content_items ci
  WHERE ci.author_did=scope.author_did
   AND ci.expires_at>$6
   AND (NOT $7 OR (ci.created_at,ci.uri)<($8,$9)
    OR ($11 AND (ci.created_at,ci.uri)=($8,$9) AND scope.publication_id<$10))
  ORDER BY ci.created_at DESC,ci.uri DESC LIMIT $1
 ) ci
 WHERE scope.scope_key=''
), batch AS MATERIALIZED (
 SELECT DISTINCT viewer_did,publication_id,author_did,uri,created_at,publication_site
 FROM raw_candidates ORDER BY created_at DESC,uri DESC,publication_id DESC LIMIT $1
), resolved AS (
 SELECT batch.*,rendered.render_json,
 COALESCE(NULLIF(rendered.render_json->>'articleUrl',''),batch.uri) article_key,
 CASE WHEN state.unread_uri IS NOT NULL THEN FALSE
      WHEN state.read_uri IS NOT NULL THEN TRUE
      ELSE COALESCE(batch.created_at<floor.read_floor_at OR
       (batch.created_at=floor.read_floor_at AND
        (floor.read_floor_uri IS NULL OR batch.uri<=floor.read_floor_uri)),FALSE) END is_read
 FROM batch JOIN content_items rendered ON rendered.uri=batch.uri
 LEFT JOIN appview_publication_read_floors floor
  ON floor.viewer_did=batch.viewer_did AND floor.publication_id=batch.publication_id
 LEFT JOIN read_marks rm ON rm.viewer_did=$3 AND rm.subject_uri=batch.uri
 LEFT JOIN appview_unread_overrides uo ON uo.viewer_did=$3 AND uo.subject_uri=batch.uri
 LEFT JOIN LATERAL appview_effective_entry_read_state($3,batch.uri,
  batch.author_did,batch.publication_site,batch.created_at,rm.subject_uri,uo.subject_uri) state ON TRUE
)
SELECT definition.updated_at,resolved.uri,resolved.render_json::text,
 resolved.created_at,resolved.publication_id,resolved.is_read,resolved.article_key
FROM feed_definition definition LEFT JOIN resolved ON TRUE
WHERE definition.updated_at IS NOT NULL
ORDER BY resolved.created_at DESC NULLS LAST,resolved.uri DESC NULLS LAST,
 resolved.publication_id DESC NULLS LAST`
