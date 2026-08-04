-- Normalize rebuildable publication scope keys for bounded feed queries.
-- PDS records remain authoritative; these rows are replaced with viewer feed projections.

CREATE TABLE IF NOT EXISTS appview_publication_scope_keys (
  viewer_did TEXT NOT NULL,
  publication_id TEXT NOT NULL,
  author_did TEXT NOT NULL,
  -- Empty string represents an author-wide scope. Real AT-URI/HTTPS keys are non-empty.
  scope_key TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (viewer_did, publication_id, scope_key),
  FOREIGN KEY (viewer_did, publication_id)
    REFERENCES appview_publication_scopes (viewer_did, publication_id)
    ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_appview_publication_scope_keys_content
  ON appview_publication_scope_keys (author_did, scope_key, viewer_did, publication_id);

CREATE OR REPLACE FUNCTION refresh_appview_publication_scope_keys()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM appview_publication_scope_keys
  WHERE viewer_did = NEW.viewer_did
    AND publication_id = NEW.publication_id;

  INSERT INTO appview_publication_scope_keys
    (viewer_did, publication_id, author_did, scope_key)
  SELECT DISTINCT
    NEW.viewer_did,
    NEW.publication_id,
    NEW.author_did,
    COALESCE(key.value, '')
  FROM (SELECT 1) seed
  LEFT JOIN LATERAL jsonb_array_elements_text(NEW.scope_keys) key(value) ON TRUE;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS appview_publication_scopes_refresh_keys
  ON appview_publication_scopes;

CREATE TRIGGER appview_publication_scopes_refresh_keys
AFTER INSERT OR UPDATE OF author_did, scope_keys
ON appview_publication_scopes
FOR EACH ROW
EXECUTE FUNCTION refresh_appview_publication_scope_keys();

INSERT INTO appview_publication_scope_keys
  (viewer_did, publication_id, author_did, scope_key)
SELECT DISTINCT
  scope.viewer_did,
  scope.publication_id,
  scope.author_did,
  COALESCE(key.value, '')
FROM appview_publication_scopes scope
LEFT JOIN LATERAL jsonb_array_elements_text(scope.scope_keys) key(value) ON TRUE
ON CONFLICT (viewer_did, publication_id, scope_key) DO UPDATE
SET author_did = EXCLUDED.author_did;

-- The original feed-membership backfill treated the sidebar's "My Publications" section as
-- subscribed feed membership. The application now excludes it, but inactive viewers never run
-- a full replacement, so clean the rebuildable legacy rows once during migration.
DELETE FROM appview_feed_publications membership
USING appview_publication_scopes scope
WHERE membership.viewer_did = scope.viewer_did
  AND membership.publication_id = scope.publication_id
  AND membership.feed_kind = 'subscribed'
  AND membership.feed_id = ''
  AND scope.section_keys ? 'my';

COMMENT ON TABLE appview_publication_scope_keys IS
  'Normalized rebuildable content-scope keys used by viewer feed queries; PDS/sidebar projection remains authoritative.';
