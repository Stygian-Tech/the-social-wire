-- Cache the richer article metadata used by The Wire's server-authored
-- presentation snapshot. These fields remain internal to the corpus and are
-- copied only into the existing public author/publishedAt presentation fields.

ALTER TABLE wire_link_metadata_cache
  ADD COLUMN IF NOT EXISTS author_name TEXT,
  ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ;

COMMENT ON COLUMN wire_link_metadata_cache.author_name IS
  'Normalized article byline selected from page metadata; never a contributing speaker identity.';
COMMENT ON COLUMN wire_link_metadata_cache.published_at IS
  'Publisher-supplied article publication timestamp parsed from page metadata.';
