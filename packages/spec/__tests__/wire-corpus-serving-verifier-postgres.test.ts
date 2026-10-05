import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const databaseURL = process.env.CORPUS_SERVING_TEST_DATABASE_URL;
const psql = process.env.PSQL_BIN ?? "psql";
const verifier = readFileSync(join(import.meta.dir, "../../../scripts/verify-wire-corpus-serving.sql"), "utf8");

function verify(prefix = "") {
  const target = new URL(databaseURL!);
  if (!["127.0.0.1", "localhost", "[::1]"].includes(target.hostname)
    || !/^\/tsw_release_[a-zA-Z0-9_]+$/.test(target.pathname)) {
    throw new Error("CORPUS_SERVING_TEST_DATABASE_URL must be an explicitly disposable local tsw_release_* database");
  }
  return spawnSync(psql, ["-X", "-qAt", "-v", "ON_ERROR_STOP=1", "--dbname", databaseURL!], {
    input: prefix + verifier, encoding: "utf8", timeout: 30_000,
  });
}

describe.skipIf(!databaseURL)("Corpus serving boundary PostgreSQL", () => {
  test("permits reviewed topic envelopes and all least-privilege serving reads", () => {
    const result = verify();
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(0);
  });

  test("rejects an unreviewed payload view", () => {
    // Error exits roll back this transaction, leaving the migrated database intact.
    const result = verify("BEGIN; CREATE VIEW wire_serving.unreviewed_payload AS SELECT '{}'::jsonb AS payload;\n");
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("wire_serving exposes forbidden internal columns");
  });

  test("still rejects score columns on a reviewed envelope view", () => {
    const result = verify(`BEGIN; CREATE OR REPLACE VIEW wire_serving.sports_events WITH (security_barrier = TRUE) AS
      SELECT event_id, competition_id, payload, updated_at, expires_at, 1 AS score
      FROM public.sports_events WHERE expires_at > CURRENT_TIMESTAMP;\n`);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("wire_serving exposes forbidden internal columns");
  });
});
