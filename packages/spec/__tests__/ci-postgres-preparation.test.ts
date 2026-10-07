import { afterEach, describe, expect, it } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const fixtures: string[] = [];
afterEach(() => {
  for (const fixture of fixtures.splice(0)) rmSync(fixture, { recursive: true, force: true });
});

function prepare(options: { idempotence?: string; fail?: boolean; database?: string }) {
  const root = mkdtempSync(join(tmpdir(), "ci-postgres-preparation-"));
  fixtures.push(root);
  mkdirSync(join(root, "scripts"));
  copyFileSync(join(import.meta.dir, "../../../scripts/ci-prepare-postgres.sh"), join(root, "scripts/ci-prepare-postgres.sh"));
  const calls = join(root, "calls");
  writeFileSync(join(root, "scripts/apply-database-migrations.sh"), '#!/usr/bin/env bash\nset -euo pipefail\nprintf "%s\\n" "$DATABASE_URL" >> "$CALLS"\nif [[ "$FAIL" == "true" ]]; then exit 17; fi\n');
  const result = spawnSync("bash", [join(root, "scripts/ci-prepare-postgres.sh")], {
    env: { ...process.env, DATABASE_URL: options.database ?? "postgresql://disposable-test", VERIFY_IDEMPOTENCE: options.idempotence ?? "false", FAIL: String(options.fail ?? false), CALLS: calls },
    encoding: "utf8",
  });
  let applied: string[] = [];
  try { applied = readFileSync(calls, "utf8").trim().split("\n"); } catch { /* Validation may reject before applying. */ }
  return { result, applied };
}

describe("CI canonical PostgreSQL preparation", () => {
  it("applies the canonical runner once with the selected database", () => {
    const { result, applied } = prepare({});
    expect(result.status).toBe(0);
    expect(applied).toEqual(["postgresql://disposable-test"]);
  });
  it("reruns the canonical runner only for explicit idempotence verification", () => {
    const { result, applied } = prepare({ idempotence: "true" });
    expect(result.status).toBe(0);
    expect(applied).toEqual(["postgresql://disposable-test", "postgresql://disposable-test"]);
  });
  it("propagates migration failure without a second attempt", () => {
    const { result, applied } = prepare({ idempotence: "true", fail: true });
    expect(result.status).toBe(17);
    expect(applied).toHaveLength(1);
  });
  it("rejects an empty database URL before running migrations", () => {
    const { result, applied } = prepare({ database: "" });
    expect(result.status).not.toBe(0);
    expect(applied).toHaveLength(0);
  });
  it("rejects invalid idempotence settings before running migrations", () => {
    const { result, applied } = prepare({ idempotence: "yes" });
    expect(result.status).not.toBe(0);
    expect(applied).toHaveLength(0);
  });
});
