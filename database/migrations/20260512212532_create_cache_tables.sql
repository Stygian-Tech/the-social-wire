-- Discovery cache backing publication lookup from a user's ATProto follow graph.
-- These tables are rebuildable caches; the authoritative source remains ATProto.

CREATE TABLE IF NOT EXISTS discovery_cache (
  user_did TEXT NOT NULL,
  publication_id TEXT NOT NULL,
  author_did TEXT NOT NULL,
  author_handle TEXT,
  title TEXT NOT NULL,
  avatar_url TEXT,
  discovered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_did, publication_id)
);

CREATE INDEX IF NOT EXISTS discovery_cache_user_did_idx
  ON discovery_cache (user_did);

CREATE INDEX IF NOT EXISTS discovery_cache_discovered_at_idx
  ON discovery_cache (user_did, discovered_at DESC);

-- Short-lived cache for sanitized entry HTML fetched from the ATProto network.
CREATE TABLE IF NOT EXISTS entry_cache (
  entry_uri TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  original_url TEXT,
  published_at TIMESTAMPTZ,
  cached_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS entry_cache_cached_at_idx
  ON entry_cache (cached_at);

-- The API service connects with the service role key and bypasses RLS.
-- Enabling RLS ensures no accidental public reads via the anon key.
ALTER TABLE discovery_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE entry_cache ENABLE ROW LEVEL SECURITY;
