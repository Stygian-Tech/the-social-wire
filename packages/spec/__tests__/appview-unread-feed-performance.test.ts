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
const postgresStore = readFileSync(
  resolve(
    root,
    "packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/PostgresThinAppViewStore.swift"
  ),
  "utf8"
);

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

  test("joins content by indexed author and publication site before read filtering", () => {
    const selectorStart = postgresStore.indexOf(
      "selector: AppViewFeedSelector"
    );
    const selectorEnd = postgresStore.indexOf(
      "public func hasViewerFeedProjection",
      selectorStart
    );
    const selectorQuery = postgresStore.slice(selectorStart, selectorEnd);

    expect(selectorQuery).toContain("matching_scope_keys AS");
    expect(selectorQuery).toContain("JOIN appview_publication_scope_keys keys");
    expect(selectorQuery).toContain(
      "ci.publication_site = scope.scope_key"
    );
    expect(selectorQuery).toContain("scope.scope_key = ''");
    expect(selectorQuery).not.toContain(
      "jsonb_array_length(scope.scope_keys) = 0"
    );
  });

  test("bulk read always removes covered overrides before recounting", () => {
    const markAllStart = postgresStore.indexOf(
      "public func markAllReadCounters"
    );
    const markAllEnd = postgresStore.indexOf(
      "public func readBoundary",
      markAllStart
    );
    const markAllQuery = postgresStore.slice(markAllStart, markAllEnd);

    expect(markAllQuery).toContain("uo.created_at <=");
    expect(markAllQuery).toContain("DELETE FROM appview_unread_overrides");
    expect(markAllQuery).toContain("SELECT COUNT(*)::int");
    expect(markAllQuery).not.toContain("shouldClearCoveredOverrides");
  });

  test("binds optional read-boundary checks with an explicit boolean type", () => {
    expect(postgresStore).toContain("\\(hasUnreadFloorUri) = TRUE");
    expect(postgresStore).toContain("\\(hasConfirmedEntryId) = TRUE");
    expect(postgresStore).toContain("\\(hasReadBoundaryEntryId) = TRUE");
    expect(postgresStore).not.toContain("\\(unreadFloorUri) IS NOT NULL");
    expect(postgresStore).not.toContain("\\(unreadFloorUri) IS NULL");
    expect(postgresStore).not.toContain("\\(confirmed.entryId) IS NOT NULL");
    expect(postgresStore).not.toContain(
      "\\(readBoundary.entryId) IS NOT NULL"
    );
  });
});
