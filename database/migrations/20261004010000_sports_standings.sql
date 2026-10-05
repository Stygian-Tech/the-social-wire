-- Optional provider context, independent from news admission and ranking.
CREATE TABLE sports_standings (
  competition_id text NOT NULL,
  season text NOT NULL,
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  updated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (competition_id, season)
);
CREATE INDEX sports_standings_expiry ON sports_standings(expires_at);
CREATE OR REPLACE VIEW wire_serving.sports_standings WITH (security_barrier = TRUE) AS
SELECT competition_id,season,payload,updated_at,expires_at FROM sports_standings WHERE expires_at>CURRENT_TIMESTAMP;
CREATE TABLE sports_schedule_status (
  competition_id text PRIMARY KEY,
  payload jsonb NOT NULL,
  updated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE OR REPLACE VIEW wire_serving.sports_schedule_status WITH (security_barrier = TRUE) AS
SELECT competition_id,payload,updated_at,expires_at FROM sports_schedule_status WHERE expires_at>CURRENT_TIMESTAMP;
DO $$
DECLARE reader RECORD;
BEGIN
  FOR reader IN
    SELECT DISTINCT privilege.grantee FROM pg_class relation
    CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault('r', relation.relowner))) privilege
    WHERE relation.oid = 'wire_serving.items'::regclass
      AND privilege.privilege_type = 'SELECT' AND privilege.grantee <> relation.relowner
  LOOP
    IF reader.grantee = 0 THEN GRANT SELECT ON wire_serving.sports_standings,wire_serving.sports_schedule_status TO PUBLIC;
    ELSE EXECUTE format('GRANT SELECT ON wire_serving.sports_standings,wire_serving.sports_schedule_status TO %I', pg_get_userbyid(reader.grantee)); END IF;
  END LOOP;
END $$;
