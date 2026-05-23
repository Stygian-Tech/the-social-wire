-- Speed scoped publication entry scans in Thin AppView.
CREATE INDEX IF NOT EXISTS idx_content_items_author_publication_site_created
  ON content_items (author_did, publication_site, created_at DESC);
