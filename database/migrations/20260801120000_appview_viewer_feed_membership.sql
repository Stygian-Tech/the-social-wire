-- Rebuildable viewer feed membership. PDS records remain authoritative.

CREATE TABLE IF NOT EXISTS appview_viewer_feeds (
  viewer_did TEXT NOT NULL,
  feed_kind TEXT NOT NULL CHECK (feed_kind IN ('subscribed', 'following', 'folder')),
  feed_id TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (viewer_did, feed_kind, feed_id)
);

CREATE TABLE IF NOT EXISTS appview_feed_publications (
  viewer_did TEXT NOT NULL,
  feed_kind TEXT NOT NULL CHECK (feed_kind IN ('subscribed', 'following', 'folder')),
  feed_id TEXT NOT NULL DEFAULT '',
  publication_id TEXT NOT NULL,
  PRIMARY KEY (viewer_did, feed_kind, feed_id, publication_id),
  FOREIGN KEY (viewer_did, feed_kind, feed_id)
    REFERENCES appview_viewer_feeds (viewer_did, feed_kind, feed_id)
    ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_appview_feed_publications_scope
  ON appview_feed_publications (viewer_did, feed_kind, feed_id, publication_id);

CREATE INDEX IF NOT EXISTS idx_appview_feed_publications_publication
  ON appview_feed_publications (viewer_did, publication_id);

-- Every viewer with a materialized publication projection has known top-level feeds,
-- including viewers whose Following feed is empty.
INSERT INTO appview_viewer_feeds (viewer_did, feed_kind, feed_id, updated_at)
SELECT DISTINCT viewer_did, kind, '', MAX(updated_at)
FROM appview_publication_scopes
CROSS JOIN (VALUES ('subscribed'), ('following')) AS feed_kinds(kind)
GROUP BY viewer_did, kind
ON CONFLICT (viewer_did, feed_kind, feed_id) DO UPDATE
SET updated_at = GREATEST(appview_viewer_feeds.updated_at, EXCLUDED.updated_at);

INSERT INTO appview_viewer_feeds (viewer_did, feed_kind, feed_id, updated_at)
SELECT scope.viewer_did, 'folder', substring(section.value FROM 8), MAX(scope.updated_at)
FROM appview_publication_scopes scope
CROSS JOIN LATERAL jsonb_array_elements_text(scope.section_keys) AS section(value)
WHERE section.value LIKE 'folder:%'
GROUP BY scope.viewer_did, substring(section.value FROM 8)
ON CONFLICT (viewer_did, feed_kind, feed_id) DO UPDATE
SET updated_at = GREATEST(appview_viewer_feeds.updated_at, EXCLUDED.updated_at);

INSERT INTO appview_feed_publications (viewer_did, feed_kind, feed_id, publication_id)
SELECT DISTINCT scope.viewer_did, 'subscribed', '', scope.publication_id
FROM appview_publication_scopes scope
WHERE scope.section_keys ?| ARRAY['my', 'subscribed:unfoldered']
   OR EXISTS (
     SELECT 1 FROM jsonb_array_elements_text(scope.section_keys) section(value)
     WHERE section.value LIKE 'folder:%'
   )
ON CONFLICT DO NOTHING;

INSERT INTO appview_feed_publications (viewer_did, feed_kind, feed_id, publication_id)
SELECT DISTINCT scope.viewer_did, 'following', '', scope.publication_id
FROM appview_publication_scopes scope
WHERE scope.section_keys ? 'following'
ON CONFLICT DO NOTHING;

INSERT INTO appview_feed_publications (viewer_did, feed_kind, feed_id, publication_id)
SELECT DISTINCT scope.viewer_did, 'folder', substring(section.value FROM 8), scope.publication_id
FROM appview_publication_scopes scope
CROSS JOIN LATERAL jsonb_array_elements_text(scope.section_keys) AS section(value)
WHERE section.value LIKE 'folder:%'
ON CONFLICT DO NOTHING;

COMMENT ON TABLE appview_viewer_feeds IS 'Rebuildable viewer feed definitions materialized from PDS-authoritative sidebar records.';
COMMENT ON TABLE appview_feed_publications IS 'Rebuildable publication membership for bounded AppView feed reads.';
