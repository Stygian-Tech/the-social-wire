-- Private AppView state for the authenticated Your Circle feed. Viewer identity is
-- keyed by the versioned HMAC used elsewhere at the corpus boundary. The graph
-- payload is private relationship state used only to reconstruct a complete snapshot.

CREATE TABLE IF NOT EXISTS appview_circle_graph_snapshots (
  viewer_key_hash TEXT PRIMARY KEY,
  snapshot_id UUID NOT NULL UNIQUE,
  graph_digest TEXT NOT NULL,
  direct_count INTEGER NOT NULL,
  one_hop_count INTEGER NOT NULL,
  actor_facts JSONB NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL,
  fresh_until TIMESTAMPTZ NOT NULL,
  stale_until TIMESTAMPTZ NOT NULL,
  CONSTRAINT appview_circle_graph_viewer_hash_length
    CHECK (char_length(viewer_key_hash) BETWEEN 16 AND 160),
  CONSTRAINT appview_circle_graph_digest_length
    CHECK (char_length(graph_digest) BETWEEN 16 AND 160),
  CONSTRAINT appview_circle_graph_direct_count
    CHECK (direct_count BETWEEN 0 AND 500),
  CONSTRAINT appview_circle_graph_one_hop_count
    CHECK (one_hop_count BETWEEN 0 AND 20000),
  CONSTRAINT appview_circle_graph_actor_facts_array
    CHECK (jsonb_typeof(actor_facts) = 'array'),
  CONSTRAINT appview_circle_graph_expiry_order
    CHECK (generated_at <= fresh_until AND fresh_until <= stale_until)
);

CREATE INDEX IF NOT EXISTS appview_circle_graph_expiry_idx
  ON appview_circle_graph_snapshots (stale_until, viewer_key_hash);

COMMENT ON TABLE appview_circle_graph_snapshots IS
  'Private, complete-only Your Circle graph snapshots. actor_facts is never exposed by a public API and is deleted by viewer privacy purge.';

CREATE TABLE IF NOT EXISTS appview_circle_hidden_items (
  viewer_key_hash TEXT NOT NULL,
  -- Deliberately not a foreign key: a hide must survive corpus retention and still
  -- apply if the canonical story is admitted again later.
  canonical_key TEXT NOT NULL,
  hidden_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (viewer_key_hash, canonical_key),
  CONSTRAINT appview_circle_hidden_viewer_hash_length
    CHECK (char_length(viewer_key_hash) BETWEEN 16 AND 160)
);

CREATE INDEX IF NOT EXISTS appview_circle_hidden_cleanup_idx
  ON appview_circle_hidden_items (viewer_key_hash, hidden_at DESC);

COMMENT ON TABLE appview_circle_hidden_items IS
  'Private cross-device Your Circle hides. Rows persist until undo or viewer privacy purge.';

CREATE TABLE IF NOT EXISTS appview_circle_edition_cache (
  viewer_key_hash TEXT NOT NULL,
  snapshot_id UUID NOT NULL,
  generation_id TEXT NOT NULL,
  language_code TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (viewer_key_hash, snapshot_id, generation_id, language_code),
  CONSTRAINT appview_circle_edition_viewer_hash_length
    CHECK (char_length(viewer_key_hash) BETWEEN 16 AND 160),
  CONSTRAINT appview_circle_edition_language_length
    CHECK (char_length(language_code) BETWEEN 2 AND 8),
  CONSTRAINT appview_circle_edition_payload_object
    CHECK (jsonb_typeof(payload) = 'object')
);

CREATE INDEX IF NOT EXISTS appview_circle_edition_expiry_idx
  ON appview_circle_edition_cache (expires_at, viewer_key_hash);

COMMENT ON TABLE appview_circle_edition_cache IS
  'Private viewer-, graph-, generation-, and language-bound Your Circle editions. Responses are never shared across viewers.';

-- The Corpus Edge is a trusted internal boundary. This view deliberately includes
-- opaque actor hashes and exact source facts needed for graph matching, while still
-- inheriting every canonical item admission, moderation, target, commercial, and
-- language gate from wire_serving.items. It never exposes raw DIDs or rank scores.
CREATE OR REPLACE VIEW wire_serving.circle_signal_facts
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
  item.publication_key,
  item.publication_homepage_url,
  item.publication_icon_url,
  item.language_code,
  corpus.topic_keys,
  signal.actor_key_hash,
  signal.signal_kind,
  signal.source_uri,
  signal.occurred_at,
  signal.source_collection,
  signal.source_action
FROM wire_serving.items AS item
JOIN wire_items AS corpus
  ON corpus.canonical_key = item.canonical_key
JOIN wire_signal_events AS signal
  ON signal.canonical_key = item.canonical_key
WHERE signal.occurred_at >= CURRENT_TIMESTAMP - INTERVAL '7 days'
  AND signal.expires_at > CURRENT_TIMESTAMP
  AND (
    signal.signal_kind IN ('recommendation', 'share', 'quote', 'reply', 'repost')
    OR (
      signal.source_collection IN (
        'at.margin.note',
        'at.margin.reply',
        'at.margin.collectionItem',
        'at.margin.readingRoom',
        'network.cosmik.card',
        'network.cosmik.connection',
        'network.cosmik.collectionLink',
        'network.cosmik.collectionLinkRemoval'
      )
      AND signal.source_action <> 'like'
    )
  );

COMMENT ON VIEW wire_serving.circle_signal_facts IS
  'Trusted Your Circle candidate facts: admitted canonical stories plus opaque actor hashes and exact internal provenance; never public API output.';

CREATE OR REPLACE VIEW wire_serving.contract AS
SELECT 3::INTEGER AS contract_version;
