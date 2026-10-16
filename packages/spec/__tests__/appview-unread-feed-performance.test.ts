import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "../../..");
const migration = readFileSync(
  resolve(
    root,
    "database/migrations/20260804190000_appview_publication_scope_keys.sql"
  ),
  "utf8"
);
const feedQuery = readFileSync(resolve(root, "packages/go/appviewcore/feed_query.go"), "utf8");
const feedBatchQuery = readFileSync(resolve(root, "packages/go/appviewcore/feed_batch_query.go"), "utf8");
const feedStore = readFileSync(resolve(root, "packages/go/appviewcore/feed_store.go"), "utf8");
const markAllStore = readFileSync(resolve(root, "packages/go/appviewcore/mark_all_store.go"), "utf8");
const unreadSnapshot = readFileSync(resolve(root, "packages/go/appviewcore/unread_snapshot.go"), "utf8");

describe("AppView unread feed performance", () => {
  test("normalizes rebuildable publication scope keys with cascading ownership", () => {
    expect(migration).toContain(
      "CREATE TABLE IF NOT EXISTS appview_publication_scope_keys"
    );
    expect(migration).toContain(
      "PRIMARY KEY (viewer_did, publication_id, scope_key)"
    );
    expect(migration).toContain("ON DELETE CASCADE");
    expect(migration).toContain("jsonb_array_elements_text(scope.scope_keys)");
    expect(migration).toContain(
      "idx_appview_publication_scope_keys_content"
    );
    expect(migration).toContain(
      "CREATE TRIGGER appview_publication_scopes_refresh_keys"
    );
    expect(migration).toContain(
      "AFTER INSERT OR UPDATE OF author_did, scope_keys"
    );
  });

  test("binds viewer-owned scope keys before bounded candidates and read authority", () => {
    expect(feedQuery).toContain("matching_scope_keys AS (");
    expect(feedQuery).toContain("FROM appview_publication_scope_keys keys");
    expect(feedQuery).toContain("membership.viewer_did=keys.viewer_did");
    expect(feedQuery).toContain("membership.publication_id=keys.publication_id");
    expect(feedQuery).toContain("keys.viewer_did=$3");
    expect(feedQuery).toContain("keys.viewer_did=scope.viewer_did");
    expect(feedQuery).toContain("keys.publication_id=scope.publication_id");
    expect(feedQuery).toContain("scope.viewer_did=$3");
    expect(feedBatchQuery).toContain("const feedBatchQuery = feedScopeQuery +");
    expect(feedBatchQuery).toContain("ci.author_did=scope.author_did");
    expect(feedBatchQuery).toContain("ci.publication_site=scope.scope_key");
    expect(feedBatchQuery).toContain("WHERE scope.scope_key=''");
    expect(feedBatchQuery).not.toContain("jsonb_array_length(scope.scope_keys)");
    const batch = feedBatchQuery.indexOf("batch AS MATERIALIZED (");
    const authority = feedBatchQuery.indexOf("LEFT JOIN LATERAL appview_effective_entry_read_state(");
    expect(batch).toBeGreaterThan(feedBatchQuery.indexOf("raw_candidates AS ("));
    expect(authority).toBeGreaterThan(batch);
    expect(feedBatchQuery).toContain("state.unread_uri IS NOT NULL THEN FALSE");
    expect(feedBatchQuery).toContain("state.read_uri IS NOT NULL THEN TRUE");
    expect(feedBatchQuery).toContain("batch.created_at<floor.read_floor_at");
  });

  test("continues bounded batches through sparse filters with dedupe before read filtering", () => {
    expect(feedBatchQuery).toContain("ORDER BY ci.created_at DESC,ci.uri DESC LIMIT $1");
    expect(feedBatchQuery).toContain("ORDER BY created_at DESC,uri DESC,publication_id DESC LIMIT $1");
    expect(feedStore).toContain("batchSize := max(32, limit+1)");
    expect(feedStore).toContain("for {");
    expect(feedStore).toContain("s.DB.QueryContext(ctx, feedBatchQuery");
    const dedupe = feedStore.indexOf("seen[article.String] = true");
    const filter = feedStore.indexOf('if filter == "unread" && read.Bool');
    const accepted = feedStore.indexOf("accepted++");
    const decode = feedStore.indexOf(".Entry()", accepted);
    expect(dedupe).toBeGreaterThanOrEqual(0);
    expect(filter).toBeGreaterThan(dedupe);
    expect(accepted).toBeGreaterThan(filter);
    expect(decode).toBeGreaterThan(accepted);
    // A full raw batch continues even when every row was read or duplicated.
    expect(feedStore).toContain("if accepted > limit || scanned < batchSize {");
    expect(feedStore).toContain("if err := ctx.Err(); err != nil");
    expect(feedStore).toContain("hasCursor, internalCursor = true, true");
    expect(feedStore).not.toContain("context.WithTimeout");
    expect(feedStore).toContain("at, uri, publicationCursor = created.Time, rowURI.String, publication.String");
    expect(feedBatchQuery).toContain("(ci.created_at,ci.uri)=($8,$9) AND scope.publication_id<$10");
    expect(feedStore).toContain("EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}");
  });

  test("bulk read deletes covered viewer/publication overrides before recounting in its transaction", () => {
    expect(markAllStore).toContain("uo.viewer_did=$1 AND uo.created_at<=$2 AND ci.author_did=$3");
    expect(markAllStore).toContain("boundary.contains(created, uri)");
    expect(markAllStore).toContain("thinappviewcore.MatchesPublication(");
    const deletion = markAllStore.indexOf("DELETE FROM appview_unread_overrides WHERE viewer_did=$1 AND subject_uri=ANY($2::text[])");
    const recount = markAllStore.indexOf("tx.QueryRowContext(ctx, markAllCountSQL");
    const commit = markAllStore.indexOf("tx.Commit()");
    expect(deletion).toBeGreaterThanOrEqual(0);
    expect(recount).toBeGreaterThan(deletion);
    expect(commit).toBeGreaterThan(recount);
    expect(markAllStore).toContain("SELECT COUNT(*)::int");
    expect(markAllStore).toContain("read_state.read_uri IS NULL");
  });

  test("binds optional cursor and read-boundary presence as typed booleans", () => {
    expect(markAllStore).toContain("$5::boolean AND ci.created_at=$4 AND ci.uri>$6::text");
    expect(markAllStore).toContain("boundary.EntryID != nil, boundary.EntryID");
    expect(markAllStore).toContain("$7::boolean=FALSE OR ci.publication_site=ANY($8::text[])");
    expect(unreadSnapshot).toContain("$7::boolean=FALSE OR ci.created_at<$8");
    expect(unreadSnapshot).toContain('cursor != "", at, uri, limit+1');
    const countQuery = markAllStore.slice(markAllStore.indexOf("const markAllCountSQL"));
    expect(countQuery).not.toMatch(/\$6(?:\s+|::text\s+)IS (?:NOT )?NULL/);
  });
});
