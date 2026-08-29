import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const migration = readFileSync(
  join(
    import.meta.dir,
    "../../../database/migrations/20260828210000_add_wire_metadata_language.sql",
  ),
  "utf8",
);

describe("The Wire metadata language migration", () => {
  it("persists bounded page-language backfill state", () => {
    expect(migration).toStartWith("-- socialwire:transaction=off");
    expect(migration).toContain("ADD COLUMN IF NOT EXISTS language_code TEXT");
    expect(migration).toContain("ADD COLUMN IF NOT EXISTS language_checked_at TIMESTAMPTZ");
    expect(migration).toContain(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_link_metadata_cache_language_backfill_idx",
    );
    expect(migration).toContain("language_checked_at IS NULL");
  });
});
