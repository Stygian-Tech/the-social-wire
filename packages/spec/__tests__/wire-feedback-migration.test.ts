import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const migration = readFileSync(
  join(
    repositoryRoot,
    "database/migrations/20260822220000_add_wire_article_feedback.sql",
  ),
  "utf8",
);
const corpusViews = readFileSync(
  join(
    repositoryRoot,
    "database/migrations/20260821190000_add_wire_corpus_serving_views.sql",
  ),
  "utf8",
);

describe("The Wire article feedback migration", () => {
  it("stores one HMAC-only assessment per viewer and story with bounded expiry", () => {
    expect(migration).toContain("PRIMARY KEY (canonical_key, actor_key_hash)");
    expect(migration).toContain("source_uri TEXT NOT NULL UNIQUE");
    expect(migration).toContain("feedback_value IN ('good', 'not_good')");
    expect(migration).toContain("wire_article_feedback_expires_idx");
    expect(migration).not.toContain("repo_did");
  });

  it("keeps feedback counts out of Corpus Edge serving views", () => {
    expect(corpusViews).not.toContain("positive_feedback_24h");
    expect(corpusViews).not.toContain("negative_feedback_24h");
    expect(corpusViews).not.toContain("actor_key_hash");
  });
});
