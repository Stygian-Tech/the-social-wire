import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const migration = readFileSync(
  join(import.meta.dir, "../../../database/migrations/20260914193000_align_wire_corpus_fallback_baseline.sql"),
  "utf8",
);

describe("Corpus fallback baseline serving contract", () => {
  it("keeps the restricted view and copies only existing reader grants while exposing baseline rollups", () => {
    expect(migration).toContain("CREATE OR REPLACE VIEW wire_serving.fallback_candidates");
    expect(migration).toContain("security_barrier = TRUE");
    expect(migration).toContain("privilege.privilege_type = 'SELECT'");
    expect(migration).not.toContain("CREATE OR REPLACE VIEW wire_serving.fallback_items");
    expect(migration).toContain("AS baseline_admitted");
    expect(migration).not.toMatch(/\b(?:DROP|TRUNCATE|UPDATE|DELETE)\b/);
    expect(migration).toContain("rollup.baseline_distinct_actors_24h");
    expect(migration).toContain("rollup.baseline_shares_1h");
    expect(migration).not.toMatch(/FROM wire_signals\b/);
  });

  it("keeps baseline label policy broad and uses baseline admission including fresh single shares", () => {
    expect(migration).toContain("label.label_value IN ('block', 'exclude', 'adult', 'graphic', 'spam')");
    expect(migration).not.toContain("label.label_key");
    expect(migration).toContain("rollup.baseline_shares_24h >= 1");
    expect(migration).toContain("INTERVAL '30 days'");
    expect(migration).toContain("item.source_confidence < 'Infinity'");
    expect(migration).not.toContain("rollup.shares_24h");
    expect(migration).not.toContain("rollup.recommendations_24h");
  });
});
