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

  test("joins indexed author/site scope keys before authoritative read filtering", () => {
    expect(feedQuery).toContain("matching_scope_keys AS (");
    expect(feedQuery).toContain("JOIN appview_publication_scope_keys keys");
    expect(feedQuery).toContain("keys.viewer_did = scope.viewer_did");
    expect(feedQuery).toContain("keys.publication_id = scope.publication_id");
    expect(feedQuery).toContain("WHERE scope.viewer_did = $3");
    expect(feedQuery).toContain("ci.author_did = scope.author_did");
    expect(feedQuery).toContain("ci.publication_site = scope.scope_key");
    expect(feedQuery).toContain("scope.scope_key = ''");
    expect(feedQuery).not.toContain("jsonb_array_length(scope.scope_keys) = 0");
    const matching = feedQuery.indexOf("matched_content AS (");
    const authority = feedQuery.indexOf("LEFT JOIN LATERAL appview_effective_entry_read_state(");
    const filteredPage = feedQuery.indexOf("), page AS (");
    expect(authority).toBeGreaterThan(matching);
    expect(filteredPage).toBeGreaterThan(authority);
  });

  test("streams ordered candidates into read authority without capping sparse unread searches", () => {
    const orderedStart = feedQuery.indexOf("ordered_candidates AS (");
    const orderedEnd = feedQuery.indexOf("), resolved AS (", orderedStart);
    expect(orderedStart).toBeGreaterThanOrEqual(0);
    expect(orderedEnd).toBeGreaterThan(orderedStart);
    const ordered = feedQuery.slice(orderedStart, orderedEnd);
    expect(ordered).toContain("ORDER BY created_at DESC, uri DESC");
    expect(ordered).toContain("OFFSET 0");
    expect(ordered).not.toMatch(/LIMIT\s+(?:\$\d+|\d+)/);
    // Only the unfiltered plan may cap content before PDS read authority resolves.
    expect(feedStore).toMatch(/if filter == "all"\s*\{\s*selection, ranking, source = feedSelectionAll/);
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
