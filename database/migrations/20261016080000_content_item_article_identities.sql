-- socialwire:transaction=off

-- Article identity is needed before read filtering. Keep it out of the large
-- render payload so exhausting a mostly-read feed never detoasts every body.
-- URLs are deliberately not indexed: publisher-controlled URLs can exceed the
-- maximum B-tree entry size. This is a rebuildable derived projection.
SET lock_timeout = '5s';
SET statement_timeout = '30min';
CREATE TABLE IF NOT EXISTS content_item_article_identities (
  uri TEXT PRIMARY KEY REFERENCES content_items(uri) ON DELETE CASCADE,
  article_key TEXT NOT NULL
);
CREATE OR REPLACE FUNCTION project_content_item_article_identity()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO content_item_article_identities(uri,article_key)
  VALUES(NEW.uri,COALESCE(NULLIF(NEW.render_json->>'articleUrl',''),NEW.uri))
  ON CONFLICT(uri) DO UPDATE SET article_key=EXCLUDED.article_key
  WHERE content_item_article_identities.article_key IS DISTINCT FROM EXCLUDED.article_key;
  RETURN NEW;
END;
$$;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='content_items'::regclass
    AND tgname='content_item_article_identity_projection') THEN
    CREATE TRIGGER content_item_article_identity_projection
    AFTER INSERT OR UPDATE OF render_json ON content_items
    FOR EACH ROW EXECUTE FUNCTION project_content_item_article_identity();
  END IF;
END;
$$;

ALTER TABLE content_item_article_identities ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
    REVOKE ALL ON content_item_article_identities FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
    REVOKE ALL ON content_item_article_identities FROM authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN
    GRANT SELECT,INSERT,UPDATE,DELETE ON content_item_article_identities TO service_role;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION project_content_item_article_identity() FROM PUBLIC;

-- Commit each small keyset batch. The trigger is already installed, so writes
-- racing the backfill project their latest key. DO NOTHING never replaces that
-- newer value with our snapshot. KEY SHARE prevents a concurrent delete from
-- invalidating the FK between selecting and inserting a row.
DO $$
DECLARE
  after_uri text;
  last_uri text;
  seek text;
BEGIN
  LOOP
    seek:=CASE WHEN after_uri IS NULL THEN '' ELSE 'WHERE ci.uri>$1' END;
    EXECUTE 'WITH batch AS MATERIALIZED (
      SELECT ci.uri,ci.render_json FROM content_items ci
      '||seek||'
      ORDER BY ci.uri LIMIT 512 FOR KEY SHARE
    ), projected AS (
      INSERT INTO content_item_article_identities(uri,article_key)
      SELECT batch.uri,COALESCE(NULLIF(batch.render_json->>''articleUrl'',''''),batch.uri)
      FROM batch LEFT JOIN content_item_article_identities existing ON existing.uri=batch.uri
      WHERE existing.uri IS NULL
      ON CONFLICT(uri) DO NOTHING RETURNING uri
    )
    SELECT max(uri) FROM batch' INTO last_uri USING after_uri;
    EXIT WHEN last_uri IS NULL;
    after_uri:=last_uri;
    COMMIT;
    PERFORM pg_sleep(0.01);
  END LOOP;
END;
$$;
RESET statement_timeout;
RESET lock_timeout;
