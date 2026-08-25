import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const migration = readFileSync(
  join(import.meta.dir, "../../../database/migrations/20260824120000_add_wire_commercial_quality_gate.sql"),
  "utf8",
);

describe("The Wire commercial quality migration", () => {
  it("persists explainable target and commercial classifications", () => {
    expect(migration).toContain("target_kind TEXT NOT NULL DEFAULT 'external_article'");
    expect(migration).toContain("commercial_score DOUBLE PRECISION NOT NULL DEFAULT 0");
    expect(migration).toContain("commercial_reasons JSONB NOT NULL DEFAULT '[]'::jsonb");
  });

  it("removes Bluesky post destinations and probable ads from every serving path", () => {
    expect(migration).toContain("THEN 'social_post'");
    expect(migration.match(/commercial_class <> 'probable_ad'/g)?.length).toBeGreaterThanOrEqual(3);
    expect(migration.match(/target_kind IN \('external_article', 'standard_site_document'\)/g)?.length)
      .toBeGreaterThanOrEqual(4);
  });
});
