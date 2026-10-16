package appviewcore

// Chunks carry only covering-index columns. Cursor grammar is fixed separately
// so continuation seeks never scan a scope's already-consumed prefix.
const feedChunkRequest = `WITH requests AS (
 SELECT * FROM jsonb_to_recordset($1::jsonb) AS r(id integer,author text,site text,at timestamptz,uri text,size integer)
) `
const feedChunkFirstQuery = feedChunkRequest + `
SELECT request.id,item.uri,item.created_at,item.publication_site FROM requests request CROSS JOIN LATERAL (
 SELECT ci.uri,ci.created_at,ci.publication_site FROM content_items ci
 WHERE request.site<>'' AND ci.author_did=request.author AND ci.publication_site=request.site AND ci.expires_at>$2
 ORDER BY ci.created_at DESC,ci.uri DESC LIMIT request.size
) item WHERE request.site<>''
UNION ALL
SELECT request.id,item.uri,item.created_at,item.publication_site FROM requests request CROSS JOIN LATERAL (
 SELECT ci.uri,ci.created_at,ci.publication_site FROM content_items ci
 WHERE request.site='' AND ci.author_did=request.author AND ci.expires_at>$2
 ORDER BY ci.created_at DESC,ci.uri DESC LIMIT request.size
) item WHERE request.site=''
ORDER BY 1,3 DESC,2 DESC`
const feedChunkCursorQuery = feedChunkRequest + `
SELECT request.id,item.uri,item.created_at,item.publication_site FROM requests request CROSS JOIN LATERAL (
 SELECT ci.uri,ci.created_at,ci.publication_site FROM content_items ci
 WHERE request.site<>'' AND ci.author_did=request.author AND ci.publication_site=request.site AND ci.expires_at>$2
 AND (ci.created_at,ci.uri)<(request.at,request.uri)
 ORDER BY ci.created_at DESC,ci.uri DESC LIMIT request.size
) item WHERE request.site<>''
UNION ALL
SELECT request.id,item.uri,item.created_at,item.publication_site FROM requests request CROSS JOIN LATERAL (
 SELECT ci.uri,ci.created_at,ci.publication_site FROM content_items ci
 WHERE request.site='' AND ci.author_did=request.author AND ci.expires_at>$2
 AND (ci.created_at,ci.uri)<(request.at,request.uri)
 ORDER BY ci.created_at DESC,ci.uri DESC LIMIT request.size
) item WHERE request.site=''
ORDER BY 1,3 DESC,2 DESC`

// PostgreSQL supplies locale-sensitive URI/publication ordering. A frontier in
// this prefix must be extended before older heads may be consumed safely.
const feedMergeQuery = `SELECT id,source,frontier FROM jsonb_to_recordset($1::jsonb)
 AS item(id bigint,source integer,uri text,at timestamptz,publication text,frontier boolean)
 ORDER BY at DESC,uri DESC,publication DESC,source DESC LIMIT $2`

// Identity and read authority are independent of the large render payload.
// Missing projection rows retain the legacy identity until backfill completes.
// LIMIT 1 keeps identity resolution as bounded URI seeks instead of rescanning
// the full projection in a hash join for every continuation batch.
const feedHydrateQuery = `WITH selected AS MATERIALIZED (
 SELECT * FROM jsonb_to_recordset($1::jsonb) AS item(id bigint,uri text,at timestamptz,publication text,author text,site text)
)
SELECT item.id,COALESCE(identity.article_key,fallback.article_key),
 CASE WHEN state.unread_uri IS NOT NULL THEN FALSE WHEN state.read_uri IS NOT NULL THEN TRUE
 ELSE COALESCE(item.at<floor.read_floor_at OR (item.at=floor.read_floor_at AND
 (floor.read_floor_uri IS NULL OR item.uri<=floor.read_floor_uri)),FALSE) END is_read
 FROM selected item
 LEFT JOIN LATERAL (SELECT projected.uri,projected.article_key
 FROM content_item_article_identities projected WHERE projected.uri=item.uri LIMIT 1) identity ON TRUE
 LEFT JOIN LATERAL (
 SELECT COALESCE(NULLIF(ci.render_json->>'articleUrl',''),ci.uri) article_key
 FROM content_items ci WHERE identity.uri IS NULL AND ci.uri=item.uri LIMIT 1
 ) fallback ON TRUE
 LEFT JOIN appview_publication_read_floors floor ON floor.viewer_did=$2 AND floor.publication_id=item.publication
 LEFT JOIN read_marks rm ON rm.viewer_did=$2 AND rm.subject_uri=item.uri
 LEFT JOIN appview_unread_overrides uo ON uo.viewer_did=$2 AND uo.subject_uri=item.uri
 LEFT JOIN LATERAL appview_effective_entry_read_state($2,item.uri,item.author,
 item.site,item.at,rm.subject_uri,uo.subject_uri) state ON TRUE
 ORDER BY item.id`

// Body hydration is restricted to deduplicated, filter-matching winners.
const feedPayloadQuery = `SELECT item.id,ci.render_json::text
 FROM jsonb_to_recordset($1::jsonb) AS item(id bigint,uri text)
 JOIN content_items ci ON ci.uri=item.uri ORDER BY item.id`
