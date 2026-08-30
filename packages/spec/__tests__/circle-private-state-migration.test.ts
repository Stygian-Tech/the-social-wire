import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const migration = readFileSync(
  join(
    import.meta.dir,
    "../../../database/migrations/20260830020000_add_circle_private_state.sql",
  ),
  "utf8",
);

describe("Your Circle private state migration", () => {
  test("stores only hashed viewer and actor identities", () => {
    expect(migration).toContain("viewer_key_hash TEXT");
    expect(migration).toContain("actor_facts JSONB");
    expect(migration).not.toMatch(/viewer_did|actor_did/i);
  });

  test("enforces graph caps and bounded stale serving", () => {
    expect(migration).toContain("direct_count BETWEEN 0 AND 500");
    expect(migration).toContain("one_hop_count BETWEEN 0 AND 20000");
    expect(migration).toContain("generated_at <= fresh_until AND fresh_until <= stale_until");
  });

  test("binds cached editions to viewer, snapshot, generation, and language", () => {
    expect(migration).toContain(
      "PRIMARY KEY (viewer_key_hash, snapshot_id, generation_id, language_code)",
    );
    expect(migration).toContain("appview_circle_edition_expiry_idx");
  });

  test("persists hides until undo or privacy purge", () => {
    expect(migration).toContain("appview_circle_hidden_items");
    expect(migration).toContain("PRIMARY KEY (viewer_key_hash, canonical_key)");
    expect(migration).not.toContain("hidden_at +");
    expect(migration).not.toContain("hidden_at < NOW()");
  });

  test("creates a strong-signal-only Corpus Edge view without rank scores", () => {
    expect(migration).toContain("wire_serving.circle_signal_facts");
    expect(migration).toContain("signal.signal_kind IN ('recommendation', 'share', 'quote', 'reply', 'repost')");
    expect(migration).toContain("signal.source_action <> 'like'");
    expect(migration).not.toMatch(/circle_signal_facts[\s\S]*ranking_score/i);
    expect(migration).toContain("SELECT 3::INTEGER AS contract_version");
  });
});
