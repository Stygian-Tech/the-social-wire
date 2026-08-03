-- Speed up AppView unread-count aggregation by author and publication scope.
CREATE INDEX IF NOT EXISTS idx_content_items_author_expires
  ON content_items (author_did, expires_at);

CREATE INDEX IF NOT EXISTS idx_content_items_author_site_expires
  ON content_items (author_did, publication_site, expires_at);

CREATE TABLE IF NOT EXISTS appview_ingestion_checkpoints (
  source TEXT NOT NULL,
  repo_did TEXT NOT NULL,
  collection TEXT NOT NULL,
  cursor TEXT,
  event_time TIMESTAMPTZ,
  observed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (source, repo_did, collection)
);

CREATE INDEX IF NOT EXISTS idx_appview_ingestion_checkpoints_observed
  ON appview_ingestion_checkpoints (observed_at);

CREATE TABLE IF NOT EXISTS rss_feed_fetch_metadata (
  feed_url TEXT PRIMARY KEY,
  etag TEXT,
  last_modified TEXT,
  last_poll_at TIMESTAMPTZ,
  backoff_until TIMESTAMPTZ,
  consecutive_error_count INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_rss_feed_fetch_metadata_backoff
  ON rss_feed_fetch_metadata (backoff_until);
