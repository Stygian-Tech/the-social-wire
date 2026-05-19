-- Thin AppView index: Level-1 content rows + derived read marks (not authoritative vs PDS).

CREATE TABLE IF NOT EXISTS content_items (
  uri TEXT PRIMARY KEY,
  cid TEXT NOT NULL,
  author_did TEXT NOT NULL,
  collection TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  indexed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  publication_site TEXT NULL,
  render_json JSONB NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_content_items_author_collection_created
  ON content_items (author_did, collection, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_content_items_expires
  ON content_items (expires_at);

CREATE TABLE IF NOT EXISTS read_marks (
  viewer_did TEXT NOT NULL,
  subject_uri TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (viewer_did, subject_uri)
);

CREATE INDEX IF NOT EXISTS idx_read_marks_viewer_created
  ON read_marks (viewer_did, created_at DESC);

COMMENT ON TABLE content_items IS 'Level-1 timeline index for standard.site entry collections; TTL via expires_at.';
COMMENT ON TABLE read_marks IS 'Derived read/unread marks mirrored from com.thesocialwire.entryReadState; purgeable per viewer.';
