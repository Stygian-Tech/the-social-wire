import { describe, expect, it } from "bun:test";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const MIGRATIONS_ROOT = join(import.meta.dir, "../../../database/migrations");

const knownHistoricalDuplicates = new Set([
  [
    "20260516144500_add_pds_repo_record_cache.sql",
    "20260516202042_add_pds_repo_record_cache.sql",
  ].join("|"),
]);

describe("database migration history", () => {
  it("does not introduce duplicate migration bodies", () => {
    const migrationsByHash = new Map<string, string[]>();

    for (const filename of readdirSync(MIGRATIONS_ROOT).filter((name) => name.endsWith(".sql"))) {
      const body = readFileSync(join(MIGRATIONS_ROOT, filename));
      const hash = createHash("sha256").update(body).digest("hex");
      const duplicates = migrationsByHash.get(hash) ?? [];
      duplicates.push(filename);
      migrationsByHash.set(hash, duplicates);
    }

    const unapprovedDuplicates = [...migrationsByHash.values()]
      .filter((filenames) => filenames.length > 1)
      .map((filenames) => filenames.sort().join("|"))
      .filter((group) => !knownHistoricalDuplicates.has(group));

    expect(unapprovedDuplicates).toEqual([]);
  });
});
