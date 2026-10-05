-- PDS selections are authoritative; these tables are rebuildable projections.
CREATE TABLE IF NOT EXISTS finance_catalog_snapshots (
  snapshot_id uuid PRIMARY KEY,
  version text NOT NULL,
  generated_at timestamptz NOT NULL,
  payload jsonb NOT NULL,
  is_active boolean NOT NULL DEFAULT false
);
CREATE UNIQUE INDEX IF NOT EXISTS finance_catalog_one_active
  ON finance_catalog_snapshots (is_active) WHERE is_active;
CREATE TABLE IF NOT EXISTS finance_instruments (
  instrument_id text PRIMARY KEY,
  provider_key text UNIQUE NOT NULL,
  payload jsonb NOT NULL,
  updated_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS finance_generations (
  generation_id uuid PRIMARY KEY,
  source_generation_id uuid NOT NULL,
  language text NOT NULL,
  algorithm_version text NOT NULL,
  generated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  payload jsonb NOT NULL,
  is_active boolean NOT NULL DEFAULT false
);
CREATE UNIQUE INDEX IF NOT EXISTS finance_generation_one_active
  ON finance_generations (language) WHERE is_active;
CREATE INDEX IF NOT EXISTS finance_generation_expiry ON finance_generations (expires_at);
CREATE TABLE IF NOT EXISTS finance_selections (
  viewer_did text NOT NULL,
  record_key text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('instrument', 'sector')),
  reference text NOT NULL,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (viewer_did, record_key)
);
CREATE TABLE IF NOT EXISTS finance_selection_sync (
  viewer_did text PRIMARY KEY,
  synced_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS finance_personalized_snapshots (
  snapshot_id uuid PRIMARY KEY,
  source_generation_id uuid NOT NULL REFERENCES finance_generations(generation_id) ON DELETE CASCADE,
  viewer_scope text NOT NULL,
  language text NOT NULL,
  preference_revision text NOT NULL,
  generated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  payload jsonb NOT NULL,
  UNIQUE (source_generation_id, viewer_scope, language, preference_revision)
);
CREATE INDEX IF NOT EXISTS finance_snapshot_expiry ON finance_personalized_snapshots (expires_at);

-- The reader receives only presentation-safe Finance candidates that still pass
-- the same current item, target, commercial and label gate as Wire.
CREATE OR REPLACE VIEW wire_serving.finance_generations WITH (security_barrier = TRUE) AS
SELECT generation.generation_id, generation.generated_at, generation.expires_at,
  generation.language, generation.is_active,
  COALESCE((SELECT jsonb_agg(candidate.value ORDER BY candidate.ordinality)
    FROM jsonb_array_elements(generation.payload) WITH ORDINALITY candidate(value, ordinality)
    JOIN wire_serving.items item ON item.canonical_key = candidate.value->'item'->>'itemId'
    WHERE generation.language = 'und' OR item.language_code = generation.language), '[]'::jsonb) AS payload,
  COALESCE((SELECT jsonb_agg(instrument.payload ORDER BY instrument.instrument_id)
    FROM finance_instruments instrument
    WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(generation.payload) candidate,
      jsonb_array_elements(candidate->'analysis'->'associations') association
      WHERE association->>'instrumentID' = instrument.instrument_id)), '[]'::jsonb) AS instruments
FROM finance_generations generation WHERE generation.expires_at > CURRENT_TIMESTAMP;
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
      GRANT SELECT ON wire_serving.finance_generations TO PUBLIC;
    ELSE
      EXECUTE format('GRANT SELECT ON wire_serving.finance_generations TO %I', pg_get_userbyid(reader.grantee));
    END IF;
  END LOOP;
END $$;

-- Event tombstones keep delayed Jetstream creates from resurrecting removed public interests.
CREATE TABLE finance_selection_versions (
  viewer_did text NOT NULL,
  record_key text NOT NULL,
  event_at timestamptz NOT NULL,
  repo_rev text NOT NULL DEFAULT '',
  is_deleted boolean NOT NULL,
  PRIMARY KEY (viewer_did, record_key)
);
ALTER TABLE finance_generations ADD COLUMN serving_source text NOT NULL DEFAULT 'ranked';
ALTER TABLE finance_personalized_snapshots ADD COLUMN serving_source text NOT NULL DEFAULT 'ranked';

-- Disposable provider request coordination across AppView replicas; no credentials stored.
CREATE TABLE finance_provider_request_budget (
  provider_key text PRIMARY KEY,
  requested_at timestamptz NOT NULL
);
