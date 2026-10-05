-- PDS selections are authoritative; these tables are rebuildable projections.
CREATE TABLE IF NOT EXISTS sports_catalog_snapshots (
  snapshot_id uuid PRIMARY KEY,
  version text NOT NULL,
  generated_at timestamptz NOT NULL,
  payload jsonb NOT NULL,
  is_active boolean NOT NULL DEFAULT false
);
CREATE UNIQUE INDEX IF NOT EXISTS sports_catalog_one_active
  ON sports_catalog_snapshots (is_active) WHERE is_active;
CREATE TABLE IF NOT EXISTS sports_entities (
  entity_id text PRIMARY KEY,
  payload jsonb NOT NULL,
  updated_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS sports_generations (
  generation_id uuid PRIMARY KEY,
  source_generation_id uuid NOT NULL,
  language text NOT NULL,
  algorithm_version text NOT NULL,
  generated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  payload jsonb NOT NULL,
  is_active boolean NOT NULL DEFAULT false
);
CREATE UNIQUE INDEX IF NOT EXISTS sports_generation_one_active
  ON sports_generations (language) WHERE is_active;
CREATE INDEX IF NOT EXISTS sports_generation_expiry ON sports_generations (expires_at);
CREATE TABLE IF NOT EXISTS sports_selections (
  viewer_did text NOT NULL,
  record_key text NOT NULL,
  action text NOT NULL CHECK (action IN ('follow', 'mute')),
  reference text NOT NULL,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (viewer_did, record_key)
);
CREATE TABLE IF NOT EXISTS sports_selection_sync (
  viewer_did text PRIMARY KEY,
  synced_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS sports_personalized_snapshots (
  snapshot_id uuid PRIMARY KEY,
  source_generation_id uuid NOT NULL REFERENCES sports_generations(generation_id) ON DELETE CASCADE,
  viewer_scope text NOT NULL,
  language text NOT NULL,
  preference_revision text NOT NULL,
  generated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  payload jsonb NOT NULL,
  UNIQUE (source_generation_id, viewer_scope, language, preference_revision)
);
CREATE INDEX IF NOT EXISTS sports_snapshot_expiry ON sports_personalized_snapshots (expires_at);

-- The reader receives only presentation-safe Sports candidates that still pass
-- the same current item, target, commercial and label gate as Wire.
CREATE OR REPLACE VIEW wire_serving.sports_generations WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, generation.generated_at, generation.expires_at,
  generation.language, generation.is_active,
  COALESCE((SELECT jsonb_agg(candidate.value ORDER BY candidate.ordinality)
    FROM jsonb_array_elements(generation.payload) WITH ORDINALITY candidate(value, ordinality)
    JOIN wire_serving.items item ON item.canonical_key = candidate.value->'item'->>'itemId'
    WHERE generation.language = 'und' OR item.language_code = generation.language), '[]'::jsonb) AS payload,
  COALESCE((SELECT payload->'entities' FROM sports_catalog_snapshots
    WHERE is_active=TRUE LIMIT 1), '[]'::jsonb) AS entities
FROM sports_generations generation WHERE generation.expires_at > CURRENT_TIMESTAMP;
DO $$
DECLARE reader RECORD;
BEGIN
  FOR reader IN
    SELECT DISTINCT privilege.grantee FROM pg_class relation
    CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault('r', relation.relowner))) privilege
    WHERE relation.oid = 'wire_serving.items'::regclass
      AND privilege.privilege_type = 'SELECT' AND privilege.grantee <> relation.relowner
  LOOP
    IF reader.grantee = 0 THEN
      GRANT SELECT ON wire_serving.sports_generations TO PUBLIC;
    ELSE
      EXECUTE format('GRANT SELECT ON wire_serving.sports_generations TO %I', pg_get_userbyid(reader.grantee));
    END IF;
  END LOOP;
END $$;

-- Event tombstones keep delayed Jetstream creates from resurrecting removed public interests.
CREATE TABLE sports_selection_versions (
  viewer_did text NOT NULL,
  record_key text NOT NULL,
  event_at timestamptz NOT NULL,
  repo_rev text NOT NULL DEFAULT '',
  is_deleted boolean NOT NULL,
  PRIMARY KEY (viewer_did, record_key)
);
ALTER TABLE sports_generations ADD COLUMN serving_source text NOT NULL DEFAULT 'ranked';
ALTER TABLE sports_personalized_snapshots ADD COLUMN serving_source text NOT NULL DEFAULT 'ranked';

-- Disposable provider request coordination across AppView replicas; no credentials stored.
CREATE TABLE sports_provider_request_budget (
  provider_key text PRIMARY KEY,
  requested_at timestamptz NOT NULL
);

-- Rebuildable article resolution belongs to Projection Pool. Coordinator only reads
-- exact source/catalog/resolver matches when constructing immutable generations.
CREATE TABLE sports_article_analysis (
  canonical_key text PRIMARY KEY REFERENCES wire_items(canonical_key) ON DELETE CASCADE,
  source_fingerprint text NOT NULL,
  catalog_revision text NOT NULL,
  resolver_version text NOT NULL,
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  analyzed_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE INDEX sports_article_analysis_expiry ON sports_article_analysis (expires_at);
COMMENT ON TABLE sports_article_analysis IS
  'Private rebuildable Sports article analysis; no prices or viewer selections. Projection Pool writes, Coordinator reads.';

CREATE TABLE sports_events (
  event_id text PRIMARY KEY,
  competition_id text NOT NULL,
  payload jsonb NOT NULL,
  updated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE INDEX sports_event_competition ON sports_events(competition_id, expires_at);
CREATE INDEX sports_event_expiry ON sports_events(expires_at);
CREATE TABLE sports_provider_refresh (
  resource_key text PRIMARY KEY,
  requested_at timestamptz NOT NULL
);
COMMENT ON TABLE sports_events IS 'Shared optional event context. Never used for article admission or ranking.';

CREATE OR REPLACE VIEW wire_serving.sports_events WITH (security_barrier = TRUE) AS
SELECT event_id,competition_id,payload,updated_at,expires_at FROM sports_events WHERE expires_at>CURRENT_TIMESTAMP;
DO $$
DECLARE reader RECORD;
BEGIN
  FOR reader IN
    SELECT DISTINCT privilege.grantee FROM pg_class relation
    CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault('r', relation.relowner))) privilege
    WHERE relation.oid = 'wire_serving.items'::regclass
      AND privilege.privilege_type = 'SELECT' AND privilege.grantee <> relation.relowner
  LOOP
    IF reader.grantee = 0 THEN GRANT SELECT ON wire_serving.sports_events TO PUBLIC;
    ELSE EXECUTE format('GRANT SELECT ON wire_serving.sports_events TO %I', pg_get_userbyid(reader.grantee)); END IF;
  END LOOP;
END $$;
