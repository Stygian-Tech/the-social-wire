import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "../../..");
const openapi = readFileSync(resolve(root, "packages/spec/openapi.yaml"), "utf8");
const migration = readFileSync(
  resolve(
    root,
    "database/migrations/20260728200000_appview_read_watermark_boundaries.sql"
  ),
  "utf8"
);

describe("AppView feed reliability contract", () => {
  it("requires authoritative read state and typed retry diagnostics", () => {
    expect(openapi).toContain("required: [entryId, title, publishedAt, isRead]");
    expect(openapi).toContain("required: [error, message, requestId, retryable]");
    expect(openapi).toContain(
      'schema: { $ref: "#/components/schemas/AppViewFeedError" }'
    );
  });

  it("documents confirmed tuple boundaries for mark-all-read", () => {
    expect(openapi).toContain(
      "required: [marked, confirmedAt, boundaries, unreadCounts]"
    );
    expect(openapi).toContain("required: [publicationId, createdAt]");
  });

  it("adds tuple floors and explicit unread overrides without rewriting history", () => {
    expect(migration).toContain("ADD COLUMN IF NOT EXISTS read_floor_uri TEXT");
    expect(migration).toContain("CREATE TABLE IF NOT EXISTS appview_unread_overrides");
    expect(migration).not.toContain("UPDATE appview_publication_read_floors");
  });
});
