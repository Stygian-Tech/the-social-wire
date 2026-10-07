package wireworkercore

const seedEmbeddedMetadataSQL = `INSERT INTO wire_link_metadata_cache
  (canonical_key, canonical_url, title, description, image_url, site_name, author_name,
   published_at, icon_url,
   etag, last_modified, source, status, fetched_at, fresh_until, stale_until,
   retry_after, failure_count, updated_at)
VALUES
  ($1, $2, $3, $4,
   $5, $6, $7,
   $8, $9, NULL, NULL,
   'embedded_card', 'pending', $10, $10,
   $11,
   $10, 0, $10)
ON CONFLICT (canonical_key) DO UPDATE SET
  source = CASE WHEN wire_link_metadata_cache.source IN ('pending', 'fallback')
    THEN 'embedded_card' ELSE wire_link_metadata_cache.source END,
  title = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.title ELSE COALESCE(EXCLUDED.title, wire_link_metadata_cache.title) END,
  description = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.description ELSE COALESCE(EXCLUDED.description, wire_link_metadata_cache.description) END,
  image_url = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.image_url ELSE COALESCE(EXCLUDED.image_url, wire_link_metadata_cache.image_url) END,
  author_name = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.author_name ELSE COALESCE(EXCLUDED.author_name, wire_link_metadata_cache.author_name) END,
  published_at = CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.published_at ELSE COALESCE(EXCLUDED.published_at, wire_link_metadata_cache.published_at) END,
  site_name = CASE WHEN wire_link_metadata_cache.source IN ('pending', 'fallback')
    THEN COALESCE(EXCLUDED.site_name, wire_link_metadata_cache.site_name)
    ELSE wire_link_metadata_cache.site_name END,
  icon_url = CASE WHEN wire_link_metadata_cache.source IN ('pending', 'fallback')
    THEN COALESCE(EXCLUDED.icon_url, wire_link_metadata_cache.icon_url)
    ELSE wire_link_metadata_cache.icon_url END,
  stale_until = GREATEST(wire_link_metadata_cache.stale_until, EXCLUDED.stale_until),
  retry_after = COALESCE(wire_link_metadata_cache.retry_after, EXCLUDED.retry_after),
  updated_at = EXCLUDED.updated_at
WHERE ROW(
  wire_link_metadata_cache.source,
  wire_link_metadata_cache.site_name,
  wire_link_metadata_cache.icon_url,
  wire_link_metadata_cache.title,
  wire_link_metadata_cache.description,
  wire_link_metadata_cache.image_url,
  wire_link_metadata_cache.author_name,
  wire_link_metadata_cache.published_at,
  wire_link_metadata_cache.stale_until,
  wire_link_metadata_cache.retry_after)
  IS DISTINCT FROM ROW(
  CASE WHEN wire_link_metadata_cache.source IN ('pending', 'fallback')
    THEN 'embedded_card' ELSE wire_link_metadata_cache.source END,
  CASE WHEN wire_link_metadata_cache.source IN ('pending', 'fallback')
    THEN COALESCE(EXCLUDED.site_name, wire_link_metadata_cache.site_name)
    ELSE wire_link_metadata_cache.site_name END,
  CASE WHEN wire_link_metadata_cache.source IN ('pending', 'fallback')
    THEN COALESCE(EXCLUDED.icon_url, wire_link_metadata_cache.icon_url)
    ELSE wire_link_metadata_cache.icon_url END,
  CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.title ELSE COALESCE(EXCLUDED.title, wire_link_metadata_cache.title) END,
  CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.description ELSE COALESCE(EXCLUDED.description, wire_link_metadata_cache.description) END,
  CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.image_url ELSE COALESCE(EXCLUDED.image_url, wire_link_metadata_cache.image_url) END,
  CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.author_name ELSE COALESCE(EXCLUDED.author_name, wire_link_metadata_cache.author_name) END,
  CASE WHEN wire_link_metadata_cache.source = 'open_graph'
    THEN wire_link_metadata_cache.published_at ELSE COALESCE(EXCLUDED.published_at, wire_link_metadata_cache.published_at) END,
  GREATEST(wire_link_metadata_cache.stale_until, EXCLUDED.stale_until),
  COALESCE(wire_link_metadata_cache.retry_after, EXCLUDED.retry_after))`
