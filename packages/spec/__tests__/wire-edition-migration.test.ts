import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const migration = readFileSync(
  join(import.meta.dir, "../../../database/migrations/20260821210000_add_wire_news_edition.sql"),
  "utf8",
);
const generationStore = readFileSync(
  join(import.meta.dir, "../../../services/wire-worker/Sources/WireWorker/PostgresWireGenerationStore.swift"),
  "utf8",
);
const corpusStore = readFileSync(
  join(import.meta.dir, "../../../services/wire-corpus-edge/Sources/WireCorpusEdge/PostgresWireCorpusStore.swift"),
  "utf8",
);

describe("The Wire news edition migration", () => {
  it("materializes normalized generation, module, story, and people selections", () => {
    for (const table of [
      "wire_edition_generations",
      "wire_edition_modules",
      "wire_edition_module_items",
      "wire_edition_talked_accounts",
    ]) {
      expect(migration).toContain(`CREATE TABLE IF NOT EXISTS ${table}`);
    }
    expect(migration).toContain("REFERENCES wire_rank_generations(generation_id)");
    expect(migration).toContain("UNIQUE (generation_id, module_key, canonical_key)");
    expect(generationStore).toContain("INSERT INTO wire_edition_generations");
    expect(generationStore).toContain("INSERT INTO wire_edition_modules");
    expect(generationStore).toContain("INSERT INTO wire_edition_module_items");
    expect(generationStore).toContain("INSERT INTO wire_edition_talked_accounts");
    expect(corpusStore).toContain("FROM wire_serving.edition_generations");
    expect(corpusStore).toContain("FROM wire_serving.edition_module_items");
    expect(corpusStore).not.toContain("talkedAboutAccountCandidates: accounts");
  });

  it("keeps metadata and mention refresh projections bounded", () => {
    expect(migration).toContain("wire_link_metadata_cache_due_idx");
    expect(migration).toContain("wire_link_metadata_cache_stale_idx");
    expect(migration).toContain("wire_item_mentions_expiry_idx");
    expect(migration).toContain("wire_talked_accounts_refresh_idx");
    expect(migration).toContain("status IN ('pending', 'fresh', 'failed')");
  });

  it("exposes only presentation-safe edition fields through Corpus Edge views", () => {
    const servingViews = migration.slice(migration.indexOf("CREATE OR REPLACE VIEW wire_serving.contract"));
    expect(servingViews).not.toContain("speaker_key_hash");
    expect(servingViews).not.toContain("distinct_story");
    expect(servingViews).not.toContain("distinct_speaker");
    expect(servingViews).not.toContain("score");
    expect(servingViews).not.toContain("actor_key_hash");
    expect(servingViews).toContain("SELECT 2::INTEGER AS contract_version");
  });
});
