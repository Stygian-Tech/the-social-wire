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
const feedQuery = readFileSync(
  resolve(import.meta.dir, "../../go/appviewcore/feed_query.go"),
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

    const matchingStart = feedQuery.indexOf("matched_content AS (");
    const matchingEnd = feedQuery.indexOf("%s\n, candidates AS (", matchingStart);
    expect(matchingStart).toBeGreaterThanOrEqual(0);
    expect(matchingEnd).toBeGreaterThan(matchingStart);
    const matchingQuery = feedQuery.slice(matchingStart, matchingEnd);
    expect(matchingQuery).toContain("ci.author_did = scope.author_did");
    expect(matchingQuery).toContain("ci.publication_site = scope.scope_key");
    expect(matchingQuery).toContain("scope.scope_key = ''");
    expect(matchingQuery).toContain("ci.created_at < $8");
    expect(matchingQuery).toContain("ci.created_at = $8 AND ci.uri < $9");
    // Matching/deduplication carries a scalar article identity, never full bodies.
    expect(matchingQuery).toContain("ci.render_json->>'articleUrl'");
    expect(matchingQuery).not.toContain("render_json::text");
    expect(matchingQuery).not.toMatch(/SELECT\s+ci\.\*/);

    const pageStart = feedQuery.indexOf("), page AS (");
    const pageLimit = feedQuery.indexOf("LIMIT $1", pageStart);
    const hydration = feedQuery.indexOf("LEFT JOIN content_items rendered ON rendered.uri = page.uri");
    expect(pageStart).toBeGreaterThan(matchingEnd);
    expect(pageLimit).toBeGreaterThan(pageStart);
    expect(hydration).toBeGreaterThan(pageLimit);
    expect(feedQuery.slice(pageStart, pageLimit)).toContain("ORDER BY created_at DESC, uri DESC");
  });
});
