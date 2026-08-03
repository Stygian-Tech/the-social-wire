-- Durable AppView projection caches (rebuildable; not authoritative vs PDS).

CREATE TABLE IF NOT EXISTS sidebar_projection_cache (
  viewer_did TEXT PRIMARY KEY,
  json_body JSONB NOT NULL,
  cached_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sidebar_projection_cache_expires
  ON sidebar_projection_cache (expires_at);

CREATE TABLE IF NOT EXISTS unread_counts_cache (
  viewer_did TEXT NOT NULL,
  publication_id TEXT NOT NULL,
  unread_count INT NOT NULL,
  cached_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (viewer_did, publication_id)
);

CREATE INDEX IF NOT EXISTS idx_unread_counts_cache_viewer_expires
  ON unread_counts_cache (viewer_did, expires_at);

CREATE TABLE IF NOT EXISTS first_page_cache (
  viewer_did TEXT NOT NULL,
  publication_id TEXT NOT NULL,
  json_body JSONB NOT NULL,
  cached_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (viewer_did, publication_id)
);

CREATE INDEX IF NOT EXISTS idx_first_page_cache_viewer_expires
  ON first_page_cache (viewer_did, expires_at);

-- Faster author-ordered entry scans (unscoped lists).
CREATE INDEX IF NOT EXISTS idx_content_items_author_created_uri
  ON content_items (author_did, created_at DESC, uri DESC);

-- Scoped publication-site scans with stable pagination tie-break.
CREATE INDEX IF NOT EXISTS idx_content_items_author_site_created_uri
  ON content_items (author_did, publication_site, created_at DESC, uri DESC);

COMMENT ON TABLE sidebar_projection_cache IS 'Cached priority/full sidebar projection JSON per viewer; TTL via expires_at.';
COMMENT ON TABLE unread_counts_cache IS 'Cached per-publication unread counts per viewer; invalidated on read-mark changes.';
COMMENT ON TABLE first_page_cache IS 'Cached first AppView entry list page per viewer/publication; invalidated on ingest/read-mark.';
