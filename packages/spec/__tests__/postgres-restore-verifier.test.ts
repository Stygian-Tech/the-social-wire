import { afterEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

function verify(overrides: Record<string, string> = {}) {
  const directory = mkdtempSync(join(tmpdir(), "socialwire-restore-verifier-"));
  directories.push(directory);
  const psql = join(directory, "psql");
  writeFileSync(psql, `#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *pg_control_system*)
    if [[ "$1" == "$SOURCE_DATABASE_URL" ]]; then
      echo '123/railway'
    else
      echo "$RESTORE_IDENTITY"
    fi ;;
  *to_regclass*)
    if [[ "$*" == *operations_service_state* && "$*" != *operations_service_heartbeats* ]]; then
      echo "$TABLES_PRESENT"
    else
      echo f
    fi ;;
  *COUNT*) echo 100 ;;
  *) exit 2 ;;
esac
`);
  chmodSync(psql, 0o755);
  return spawnSync("bash", [join(import.meta.dir, "../../../scripts/verify-postgres-restore.sh")], {
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${directory}:${process.env.PATH ?? ""}`,
      SOURCE_DATABASE_URL: "postgresql://source.invalid/railway",
      RESTORE_DATABASE_URL: "postgresql://clone.invalid/railway_restore_drill",
      CONFIRM_RESTORE_DATABASE: "railway_restore_drill",
      RESTORE_IDENTITY: "123/railway_restore_drill",
      TABLES_PRESENT: "t",
      ...overrides,
    },
  });
}

test("accepts current Operations schema on a renamed physical clone without claiming full recovery", () => {
  const result = verify();
  expect(result.status).toBe(0);
  expect(result.stdout).toContain("Restore schema checks passed");
  expect(result.stdout).toContain("durable-row integrity, restart, and rebuild checks are still required");
});

test("rejects a missing required durable table", () => {
  const result = verify({ TABLES_PRESENT: "f" });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("missing one or more required tables");
});

test("rejects a source alias despite different connection URLs", () => {
  const result = verify({ RESTORE_IDENTITY: "123/railway" });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("resolve to the same database");
});
