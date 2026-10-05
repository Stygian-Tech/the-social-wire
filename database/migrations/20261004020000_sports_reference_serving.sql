-- Public reviewed reference metadata is independent of moderated news generations.
-- Event readers must not sort article-serving views merely to obtain the catalog.
CREATE OR REPLACE VIEW wire_serving.sports_catalog WITH (security_barrier = TRUE) AS
SELECT version, generated_at, COALESCE(payload->'entities', '[]'::jsonb) AS entities
FROM sports_catalog_snapshots
WHERE is_active = TRUE;

DO $$
DECLARE reader RECORD;
BEGIN
  FOR reader IN
    SELECT DISTINCT privilege.grantee FROM pg_class relation
    CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault('r', relation.relowner))) privilege
    WHERE relation.oid = 'wire_serving.sports_events'::regclass
      AND privilege.privilege_type = 'SELECT' AND privilege.grantee <> relation.relowner
  LOOP
    IF reader.grantee = 0 THEN GRANT SELECT ON wire_serving.sports_catalog TO PUBLIC;
    ELSE EXECUTE format('GRANT SELECT ON wire_serving.sports_catalog TO %I', pg_get_userbyid(reader.grantee)); END IF;
  END LOOP;
END $$;
