-- The Wire news edition is a presentation-only projection over an immutable
-- wire-v1 generation. Internal ranks, scores, actor hashes, and cohort counts
-- stay outside the wire_serving schema and every public response.

ALTER TABLE wire_items
  ADD COLUMN IF NOT EXISTS publication_homepage_url TEXT,
  ADD COLUMN IF NOT EXISTS publication_icon_url TEXT;

CREATE TABLE IF NOT EXISTS wire_link_metadata_cache (
  canonical_key TEXT PRIMARY KEY REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  canonical_url TEXT NOT NULL,
  title TEXT,
  description TEXT,
  image_url TEXT,
  site_name TEXT,
  icon_url TEXT,
  etag TEXT,
  last_modified TEXT,
  source TEXT NOT NULL DEFAULT 'pending',
  status TEXT NOT NULL DEFAULT 'pending',
  fetched_at TIMESTAMPTZ,
  fresh_until TIMESTAMPTZ,
  stale_until TIMESTAMPTZ,
  retry_after TIMESTAMPTZ,
  failure_count INTEGER NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT wire_link_metadata_cache_source CHECK (
    source IN ('pending', 'standard_site', 'open_graph', 'embedded_card', 'fallback')
  ),
  CONSTRAINT wire_link_metadata_cache_status CHECK (
    status IN ('pending', 'fetching', 'fresh', 'stale', 'negative', 'retry', 'failed')
  ),
  CONSTRAINT wire_link_metadata_cache_failure_count CHECK (failure_count >= 0),
  CONSTRAINT wire_link_metadata_cache_freshness_order CHECK (
    fresh_until IS NULL OR stale_until IS NULL OR fresh_until <= stale_until
  )
);

CREATE INDEX IF NOT EXISTS wire_link_metadata_cache_due_idx
  ON wire_link_metadata_cache (retry_after, fresh_until, canonical_key)
  WHERE status IN ('pending', 'fresh', 'stale', 'negative', 'retry', 'failed');
CREATE INDEX IF NOT EXISTS wire_link_metadata_cache_stale_idx
  ON wire_link_metadata_cache (stale_until, canonical_key)
  WHERE stale_until IS NOT NULL;

CREATE TABLE IF NOT EXISTS wire_item_mentions (
  source_uri TEXT NOT NULL,
  canonical_key TEXT NOT NULL REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  subject_did TEXT NOT NULL,
  speaker_key_hash TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (source_uri, canonical_key, subject_did),
  CONSTRAINT wire_item_mentions_subject_did CHECK (subject_did LIKE 'did:%'),
  CONSTRAINT wire_item_mentions_speaker_hash_length CHECK (
    char_length(speaker_key_hash) BETWEEN 16 AND 160
  )
);

CREATE INDEX IF NOT EXISTS wire_item_mentions_account_aggregation_idx
  ON wire_item_mentions (subject_did, expires_at DESC, canonical_key, speaker_key_hash);
CREATE INDEX IF NOT EXISTS wire_item_mentions_canonical_key_idx
  ON wire_item_mentions (canonical_key);
CREATE INDEX IF NOT EXISTS wire_item_mentions_source_idx
  ON wire_item_mentions (source_uri, occurred_at DESC);
CREATE INDEX IF NOT EXISTS wire_item_mentions_expiry_idx
  ON wire_item_mentions (expires_at, source_uri, canonical_key);

CREATE TABLE IF NOT EXISTS wire_talked_accounts (
  subject_did TEXT PRIMARY KEY,
  handle TEXT,
  display_name TEXT,
  avatar_url TEXT,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  retry_after TIMESTAMPTZ,
  failure_count INTEGER NOT NULL DEFAULT 0,
  fetched_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  CONSTRAINT wire_talked_accounts_subject_did CHECK (subject_did LIKE 'did:%'),
  CONSTRAINT wire_talked_accounts_status CHECK (status IN ('pending', 'fresh', 'failed')),
  CONSTRAINT wire_talked_accounts_failure_count CHECK (failure_count >= 0),
  CONSTRAINT wire_talked_accounts_fresh_complete CHECK (
    status != 'fresh' OR (fetched_at IS NOT NULL AND expires_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS wire_talked_accounts_refresh_idx
  ON wire_talked_accounts (retry_after, expires_at, subject_did)
  WHERE status IN ('pending', 'failed');
CREATE INDEX IF NOT EXISTS wire_talked_accounts_expiry_idx
  ON wire_talked_accounts (expires_at, subject_did)
  WHERE status = 'fresh';

CREATE TABLE IF NOT EXISTS wire_edition_generations (
  generation_id UUID PRIMARY KEY REFERENCES wire_rank_generations(generation_id) ON DELETE CASCADE,
  algorithm_version TEXT NOT NULL DEFAULT 'wire-edition-v1',
  language_bucket TEXT NOT NULL,
  continuation_ordinal INTEGER NOT NULL DEFAULT 50,
  materialized_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT wire_edition_generations_continuation_nonnegative CHECK (continuation_ordinal >= 0)
);

CREATE INDEX IF NOT EXISTS wire_edition_generations_language_idx
  ON wire_edition_generations (language_bucket, materialized_at DESC, generation_id);

CREATE TABLE IF NOT EXISTS wire_edition_modules (
  generation_id UUID NOT NULL REFERENCES wire_edition_generations(generation_id) ON DELETE CASCADE,
  module_key TEXT NOT NULL,
  module_kind TEXT NOT NULL,
  title TEXT,
  position INTEGER NOT NULL,
  reason_code TEXT,
  publication_key TEXT,
  publication_name TEXT,
  publication_domain TEXT,
  publication_homepage_url TEXT,
  publication_icon_url TEXT,
  PRIMARY KEY (generation_id, module_key),
  UNIQUE (generation_id, position),
  CONSTRAINT wire_edition_modules_position_nonnegative CHECK (position >= 0),
  CONSTRAINT wire_edition_modules_kind CHECK (
    module_kind IN ('top_stories', 'publication_spotlight', 'story_rail', 'general', 'trending')
  )
);

CREATE INDEX IF NOT EXISTS wire_edition_modules_order_idx
  ON wire_edition_modules (generation_id, position, module_key);

CREATE TABLE IF NOT EXISTS wire_edition_module_items (
  generation_id UUID NOT NULL,
  module_key TEXT NOT NULL,
  position INTEGER NOT NULL,
  canonical_key TEXT NOT NULL REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  PRIMARY KEY (generation_id, module_key, position),
  UNIQUE (generation_id, module_key, canonical_key),
  CONSTRAINT wire_edition_module_items_module_fk
    FOREIGN KEY (generation_id, module_key)
    REFERENCES wire_edition_modules(generation_id, module_key) ON DELETE CASCADE,
  CONSTRAINT wire_edition_module_items_position_nonnegative CHECK (position >= 0)
);

CREATE INDEX IF NOT EXISTS wire_edition_module_items_story_idx
  ON wire_edition_module_items (generation_id, canonical_key);
CREATE INDEX IF NOT EXISTS wire_edition_module_items_canonical_key_idx
  ON wire_edition_module_items (canonical_key);

CREATE TABLE IF NOT EXISTS wire_edition_talked_accounts (
  generation_id UUID NOT NULL REFERENCES wire_edition_generations(generation_id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  subject_did TEXT NOT NULL REFERENCES wire_talked_accounts(subject_did) ON DELETE CASCADE,
  PRIMARY KEY (generation_id, position),
  UNIQUE (generation_id, subject_did),
  CONSTRAINT wire_edition_talked_accounts_position_nonnegative CHECK (position >= 0)
);

CREATE INDEX IF NOT EXISTS wire_edition_talked_accounts_subject_idx
  ON wire_edition_talked_accounts (subject_did);

-- Extend the presentation-safe Corpus Edge boundary. Appended columns preserve
-- the existing view shape for getWire/getWireItem consumers.
CREATE OR REPLACE VIEW wire_serving.contract AS
SELECT 2::INTEGER AS contract_version;

CREATE OR REPLACE VIEW wire_serving.items
WITH (security_barrier = TRUE) AS
SELECT
  item.canonical_key,
  item.canonical_url,
  item.representative_uri,
  item.title,
  item.summary,
  item.published_at,
  item.thumbnail_url,
  item.source_name,
  item.source_domain,
  item.publication_id,
  item.author_name,
  item.provenance,
  item.author_key,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url,
  item.publication_icon_url
FROM wire_items AS item
WHERE item.eligible = TRUE
  AND item.expires_at > CURRENT_TIMESTAMP
  AND NOT EXISTS (
    SELECT 1
    FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key
      AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
  );

CREATE OR REPLACE VIEW wire_serving.ranked_items
WITH (security_barrier = TRUE) AS
SELECT
  ranked.generation_id,
  ranked.position,
  item.canonical_key,
  item.canonical_url,
  item.representative_uri,
  item.title,
  item.summary,
  item.published_at,
  item.thumbnail_url,
  item.source_name,
  item.source_domain,
  item.publication_id,
  item.author_name,
  item.provenance,
  item.author_key,
  ranked.reason_codes,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url,
  item.publication_icon_url
FROM wire_ranked_items AS ranked
JOIN wire_rank_generations AS generation
  ON generation.generation_id = ranked.generation_id
JOIN wire_items AS item
  ON item.canonical_key = ranked.canonical_key
WHERE generation.feed_key = 'wire'
  AND generation.status IN ('committed', 'superseded')
  AND item.eligible = TRUE
  AND item.expires_at > CURRENT_TIMESTAMP
  AND NOT EXISTS (
    SELECT 1
    FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key
      AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
  );

CREATE OR REPLACE VIEW wire_serving.fallback_items
WITH (security_barrier = TRUE) AS
SELECT
  item.canonical_key,
  item.canonical_url,
  item.representative_uri,
  item.title,
  item.summary,
  item.published_at,
  item.thumbnail_url,
  item.source_name,
  item.source_domain,
  item.publication_id,
  item.author_name,
  item.provenance,
  item.author_key,
  item.language_code,
  item.topic_keys,
  item.first_seen_at,
  COALESCE(NULLIF(item.publication_id, ''), item.source_domain) AS publication_key,
  item.publication_homepage_url,
  item.publication_icon_url
FROM wire_items AS item
WHERE item.eligible = TRUE
  AND item.expires_at > CURRENT_TIMESTAMP
  AND item.source_confidence >= 0.75
  AND NOT EXISTS (
    SELECT 1
    FROM wire_labels AS label
    WHERE label.canonical_key = item.canonical_key
      AND label.expires_at > CURRENT_TIMESTAMP
      AND label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')
  );

CREATE OR REPLACE VIEW wire_serving.edition_generations AS
SELECT
  edition.generation_id,
  edition.algorithm_version,
  edition.language_bucket,
  edition.continuation_ordinal,
  generation.generated_at,
  generation.expires_at
FROM wire_edition_generations AS edition
JOIN wire_rank_generations AS generation
  ON generation.generation_id = edition.generation_id
WHERE generation.feed_key = 'wire'
  AND generation.status IN ('committed', 'superseded');

CREATE OR REPLACE VIEW wire_serving.edition_modules AS
SELECT
  module.generation_id,
  module.module_key,
  module.module_kind,
  module.title,
  module.position,
  module.reason_code,
  module.publication_key,
  module.publication_name,
  module.publication_domain,
  module.publication_homepage_url,
  module.publication_icon_url
FROM wire_edition_modules AS module
JOIN wire_serving.edition_generations AS generation
  ON generation.generation_id = module.generation_id;

CREATE OR REPLACE VIEW wire_serving.edition_module_items
WITH (security_barrier = TRUE) AS
SELECT
  module_item.generation_id,
  module_item.module_key,
  module_item.position AS module_position,
  ranked.canonical_key,
  ranked.canonical_url,
  ranked.representative_uri,
  ranked.title,
  ranked.summary,
  ranked.published_at,
  ranked.thumbnail_url,
  ranked.source_name,
  ranked.source_domain,
  ranked.publication_id,
  ranked.author_name,
  ranked.provenance,
  ranked.author_key,
  ranked.reason_codes,
  ranked.publication_key,
  ranked.publication_homepage_url,
  ranked.publication_icon_url
FROM wire_edition_module_items AS module_item
JOIN wire_serving.ranked_items AS ranked
  ON ranked.generation_id = module_item.generation_id
 AND ranked.canonical_key = module_item.canonical_key;

CREATE OR REPLACE VIEW wire_serving.edition_talked_accounts
WITH (security_barrier = TRUE) AS
SELECT
  selected.generation_id,
  selected.position,
  profile.subject_did,
  profile.handle,
  profile.display_name,
  profile.avatar_url,
  profile.description
FROM wire_edition_talked_accounts AS selected
JOIN wire_talked_accounts AS profile
  ON profile.subject_did = selected.subject_did
WHERE profile.status = 'fresh'
  AND profile.expires_at > CURRENT_TIMESTAMP;

COMMENT ON TABLE wire_link_metadata_cache IS
  'Bounded server-side presentation metadata; clients never fetch per-card OpenGraph data.';
COMMENT ON TABLE wire_item_mentions IS
  'Explicit public mention/quote edges; speaker identities are stored only as keyed hashes.';
COMMENT ON TABLE wire_edition_generations IS
  'Deterministic wire-edition-v1 materialization pinned to one immutable wire-v1 generation.';
COMMENT ON VIEW wire_serving.edition_talked_accounts IS
  'Public profile presentation only; speaker hashes and eligibility counts remain private.';
