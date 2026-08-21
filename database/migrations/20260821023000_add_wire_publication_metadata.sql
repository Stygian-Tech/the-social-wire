-- Standard Site documents identify their publication by AT-URI and carry a relative
-- path. Keep the public publication metadata needed to resolve that pair into the
-- canonical HTTPS article URL. This projection is rebuildable and PostgreSQL remains
-- authoritative; process-local caches only reduce repeated PDS reads.
CREATE TABLE IF NOT EXISTS wire_publications (
  publication_uri TEXT PRIMARY KEY,
  repo_did TEXT NOT NULL,
  site_url TEXT NOT NULL,
  name TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  first_seen_at TIMESTAMPTZ NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT wire_publications_uri_length CHECK (char_length(publication_uri) BETWEEN 1 AND 512),
  CONSTRAINT wire_publications_repo_did_length CHECK (char_length(repo_did) BETWEEN 1 AND 512),
  CONSTRAINT wire_publications_site_url_length CHECK (char_length(site_url) BETWEEN 1 AND 2048),
  CONSTRAINT wire_publications_name_length CHECK (char_length(name) BETWEEN 1 AND 500),
  CONSTRAINT wire_publications_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS wire_publications_expires_idx
  ON wire_publications (expires_at, publication_uri);
CREATE INDEX IF NOT EXISTS wire_publications_repo_idx
  ON wire_publications (repo_did, last_seen_at DESC, publication_uri);

COMMENT ON TABLE wire_publications IS
  'Rebuildable public Standard Site publication metadata used to resolve document site AT-URIs and relative paths.';
