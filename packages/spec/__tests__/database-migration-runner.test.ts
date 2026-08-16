import { afterEach, describe, expect, it } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const runner = join(repositoryRoot, "scripts/apply-database-migrations.sh");
const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const path of temporaryDirectories.splice(0)) {
    rmSync(path, { recursive: true, force: true });
  }
});

function fixture(): { root: string; migrations: string; log: string; bin: string } {
  const root = mkdtempSync(join(tmpdir(), "socialwire-migration-runner-"));
  temporaryDirectories.push(root);
  const migrations = join(root, "migrations");
  const log = join(root, "log");
  const bin = join(root, "bin");
  mkdirSync(migrations);
  mkdirSync(log);
  mkdirSync(bin);
  const fakePsql = join(bin, "psql");
  writeFileSync(
    fakePsql,
    `#!/usr/bin/env bash
set -euo pipefail
count_file="$FAKE_PSQL_LOG_DIR/count"
count=0
if [[ -f "$count_file" ]]; then count="$(<"$count_file")"; fi
count=$((count + 1))
printf '%s' "$count" >"$count_file"
printf '%s\n' "$@" >"$FAKE_PSQL_LOG_DIR/call-$count.args"
file=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-f" ]]; then file="$argument"; fi
  previous="$argument"
done
if [[ -n "$file" ]]; then
  cp "$file" "$FAKE_PSQL_LOG_DIR/call-$count.sql"
else
  cat >"$FAKE_PSQL_LOG_DIR/call-$count.sql"
fi
`,
  );
  chmodSync(fakePsql, 0o755);
  return { root, migrations, log, bin };
}

function environment(paths: ReturnType<typeof fixture>): NodeJS.ProcessEnv {
  return {
    ...process.env,
    DATABASE_URL: "postgresql://migration-runner.invalid/test",
    FAKE_PSQL_LOG_DIR: paths.log,
    MIGRATIONS_DIR: paths.migrations,
    PATH: `${paths.bin}:${process.env.PATH ?? ""}`,
  };
}

describe("database migration runner transaction modes", () => {
  it("keeps the default transactional and holds a session lock for opt-out migrations", () => {
    const paths = fixture();
    writeFileSync(join(paths.migrations, "001_default.sql"), "SELECT 'default-body';\n");
    writeFileSync(
      join(paths.migrations, "002_concurrent.sql"),
      "-- socialwire:transaction=off\nSELECT 'concurrent-body';\n",
    );

    execFileSync("bash", [runner], { env: environment(paths) });

    const transactionalArgs = readFileSync(join(paths.log, "call-2.args"), "utf8");
    const transactionalSQL = readFileSync(join(paths.log, "call-2.sql"), "utf8");
    const concurrentArgs = readFileSync(join(paths.log, "call-3.args"), "utf8");
    const concurrentSQL = readFileSync(join(paths.log, "call-3.sql"), "utf8");

    expect(transactionalArgs).toContain("--single-transaction");
    expect(transactionalSQL).toContain("SELECT pg_advisory_xact_lock(");
    expect(transactionalSQL).not.toContain("SELECT pg_advisory_unlock(");
    expect(concurrentArgs).not.toContain("--single-transaction");
    expect(concurrentSQL).toContain("SELECT pg_advisory_lock(");
    expect(concurrentSQL).toContain("SELECT pg_advisory_unlock(");
    expect(concurrentSQL.indexOf("concurrent-body"))
      .toBeLessThan(concurrentSQL.indexOf("INSERT INTO public.schema_migrations"));
    expect(concurrentSQL.indexOf("INSERT INTO public.schema_migrations"))
      .toBeLessThan(concurrentSQL.indexOf("SELECT pg_advisory_unlock("));
  });

  it("rejects malformed or duplicate transaction directives", () => {
    const paths = fixture();
    writeFileSync(
      join(paths.migrations, "001_invalid.sql"),
      "-- socialwire:transaction=off\n-- socialwire:transaction=off\nSELECT 1;\n",
    );

    const result = spawnSync("bash", [runner], {
      encoding: "utf8",
      env: environment(paths),
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("invalid or duplicate socialwire:transaction directive");
    expect(readFileSync(join(paths.log, "count"), "utf8")).toBe("1");
  });
});
