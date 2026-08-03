-- Deterministic AppView read watermarks and explicit unread overrides.

ALTER TABLE appview_publication_read_floors
  ADD COLUMN IF NOT EXISTS read_floor_uri TEXT;

CREATE TABLE IF NOT EXISTS appview_unread_overrides (
  viewer_did TEXT NOT NULL,
  subject_uri TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (viewer_did, subject_uri)
);

CREATE INDEX IF NOT EXISTS idx_appview_unread_overrides_cleanup
  ON appview_unread_overrides (created_at, viewer_did, subject_uri);

COMMENT ON COLUMN appview_publication_read_floors.read_floor_uri IS
  'Stable content_items.uri tie-breaker for the read_floor_at timeline boundary; NULL preserves legacy inclusive timestamp semantics.';
COMMENT ON TABLE appview_unread_overrides IS
  'Explicit per-entry unread choices that override older publication read watermarks.';
