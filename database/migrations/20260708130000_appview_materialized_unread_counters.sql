-- Materialized AppView sidebar scopes and unread counters.
-- These rows are rebuildable derived state; PDS records and content_items remain authoritative.

CREATE TABLE IF NOT EXISTS appview_publication_scopes (
  viewer_did TEXT NOT NULL,
  publication_id TEXT NOT NULL,
  author_did TEXT NOT NULL,
  publication_at_uri TEXT,
  publication_scope_at_uris JSONB NOT NULL DEFAULT '[]'::jsonb,
  publication_site_urls JSONB NOT NULL DEFAULT '[]'::jsonb,
  scope_keys JSONB NOT NULL DEFAULT '[]'::jsonb,
  section_keys JSONB NOT NULL DEFAULT '[]'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (viewer_did, publication_id)
);

CREATE INDEX IF NOT EXISTS idx_appview_publication_scopes_viewer
  ON appview_publication_scopes (viewer_did);

CREATE INDEX IF NOT EXISTS idx_appview_publication_scopes_author
  ON appview_publication_scopes (author_did);

CREATE INDEX IF NOT EXISTS idx_appview_publication_scopes_scope_keys
  ON appview_publication_scopes USING GIN (scope_keys);

CREATE TABLE IF NOT EXISTS appview_unread_counters (
  viewer_did TEXT NOT NULL,
  publication_id TEXT NOT NULL,
  unread_count INTEGER NOT NULL DEFAULT 0 CHECK (unread_count >= 0),
  generation BIGINT NOT NULL,
  accuracy TEXT NOT NULL CHECK (accuracy IN ('estimated', 'exact')),
  dirty BOOLEAN NOT NULL DEFAULT false,
  counted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (viewer_did, publication_id)
);

CREATE INDEX IF NOT EXISTS idx_appview_unread_counters_dirty
  ON appview_unread_counters (dirty, counted_at);

CREATE INDEX IF NOT EXISTS idx_appview_unread_counters_viewer_generation
  ON appview_unread_counters (viewer_did, generation DESC);

CREATE TABLE IF NOT EXISTS appview_publication_read_floors (
  viewer_did TEXT NOT NULL,
  publication_id TEXT NOT NULL,
  read_floor_at TIMESTAMPTZ NOT NULL,
  generation BIGINT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (viewer_did, publication_id)
);

CREATE INDEX IF NOT EXISTS idx_appview_publication_read_floors_updated
  ON appview_publication_read_floors (updated_at);

COMMENT ON TABLE appview_publication_scopes IS 'Rebuildable publication scope rows used to match content_items to viewer sidebar publications.';
COMMENT ON TABLE appview_unread_counters IS 'Rebuildable per-viewer/publication unread badges with generation and accuracy metadata.';
COMMENT ON TABLE appview_publication_read_floors IS 'Per-publication mark-all-read watermarks that prevent old backfills from re-inflating unread counters.';
