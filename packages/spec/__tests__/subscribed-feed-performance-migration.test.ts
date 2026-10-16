import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const migration = readFileSync(
  resolve(
    import.meta.dir,
    "../../../database/migrations/20260730010000_subscribed_feed_membership_index.sql"
  ),
  "utf8"
);
const keysetIndexesMigration = readFileSync(
  resolve(
    import.meta.dir,
    "../../../database/migrations/20260523180000_add_appview_projection_caches.sql"
  ),
  "utf8"
);
const feedBatchQuery = readFileSync(
  resolve(import.meta.dir, "../../go/appviewcore/feed_batch_query.go"),
  "utf8"
);

const coveringIndexMigration = readFileSync(
  resolve(import.meta.dir, "../../../database/migrations/20261016070000_cover_subscribed_feed_candidates.sql"),
  "utf8"
);

describe("Subscribed feed performance migration", () => {
  test("backfills the canonical subscribed membership marker", () => {
    expect(migration).toContain(`section_keys || '["subscribed"]'::jsonb`);
    expect(migration).toContain(`section_keys ? 'my'`);
    expect(migration).toContain(`section_keys ? 'subscribed:unfoldered'`);
    expect(migration).toContain(`section_key.value LIKE 'folder:%'`);
    expect(migration).toContain(`WHERE NOT section_keys ? 'subscribed'`);
  });

  test("adds a JSONB membership index", () => {
    expect(migration).toContain(
      "CREATE INDEX IF NOT EXISTS idx_appview_publication_scopes_section_keys"
    );
    expect(migration).toContain(
      "ON appview_publication_scopes USING GIN (section_keys)"
    );
  });

  test("uses author, site, and stable keyset indexes without selecting full bodies", () => {
    expect(keysetIndexesMigration).toContain(
      "idx_content_items_author_created_uri"
    );
    expect(keysetIndexesMigration).toContain(
      "ON content_items (author_did, created_at DESC, uri DESC)"
    );
    expect(keysetIndexesMigration).toContain(
      "idx_content_items_author_site_created_uri"
    );
    expect(keysetIndexesMigration).toContain(
      "ON content_items (author_did, publication_site, created_at DESC, uri DESC)"
    );

    const matchingStart = feedBatchQuery.indexOf("raw_candidates AS (");
    const batchStart = feedBatchQuery.indexOf("), batch AS MATERIALIZED (", matchingStart);
    const resolvedStart = feedBatchQuery.indexOf("), resolved AS (", batchStart);
    expect(matchingStart).toBeGreaterThanOrEqual(0);
    expect(batchStart).toBeGreaterThan(matchingStart);
    expect(resolvedStart).toBeGreaterThan(batchStart);
    const matchingQuery = feedBatchQuery.slice(matchingStart, batchStart);
    expect(matchingQuery).toContain("ci.author_did=scope.author_did");
    expect(matchingQuery).toContain("ci.publication_site=scope.scope_key");
    expect(matchingQuery).toContain("WHERE scope.scope_key=''");
    expect(matchingQuery).toContain("(ci.created_at,ci.uri)<($8,$9)");
    expect(matchingQuery).toContain("ORDER BY ci.created_at DESC,ci.uri DESC LIMIT $1");
    // Even scalar article identity waits until the bounded global batch, so
    // candidate index scans need no stored payload or full article body.
    expect(matchingQuery).not.toContain("render_json");
    expect(matchingQuery).not.toMatch(/SELECT\s+ci\.\*/);
    const batchQuery = feedBatchQuery.slice(batchStart, resolvedStart);
    expect(batchQuery).toContain("ORDER BY created_at DESC,uri DESC,publication_id DESC LIMIT $1");
    const hydration = feedBatchQuery.indexOf("JOIN content_items rendered ON rendered.uri=batch.uri");
    expect(hydration).toBeGreaterThan(resolvedStart);
    expect(feedBatchQuery.slice(resolvedStart)).toContain("rendered.render_json->>'articleUrl'");
  });

  test("builds the ordered expiry-covering candidate index concurrently with retry validation", () => {
    expect(coveringIndexMigration).toContain("-- socialwire:transaction=off");
    expect(coveringIndexMigration).toContain("CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_content_items_author_site_feed_cover");
    expect(coveringIndexMigration).toContain("ON content_items (author_did, publication_site, created_at DESC, uri DESC)");
    expect(coveringIndexMigration).toContain("INCLUDE (expires_at)");
    expect(coveringIndexMigration).toContain("AND NOT indisvalid");
    expect(coveringIndexMigration).toContain("DROP INDEX CONCURRENTLY IF EXISTS public.idx_content_items_author_site_feed_cover");
    expect(coveringIndexMigration).toContain("AND indisvalid AND indisready");
    expect(coveringIndexMigration).not.toContain("DROP INDEX CONCURRENTLY IF EXISTS public.idx_content_items_author_site_created_uri");
  });
});
