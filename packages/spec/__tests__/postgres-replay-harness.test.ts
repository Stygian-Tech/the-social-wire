import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

test("Postgres replay harness preserves its isolation and process cleanup boundaries", () => {
  const result = spawnSync(
    "python3",
    ["-m", "unittest", "discover", "-s", "scripts/benchmarks/tests", "-v"],
    {
      cwd: join(import.meta.dir, "../../.."),
      encoding: "utf8",
      timeout: 20_000,
    },
  );
  expect(result.error).toBeUndefined();
  expect(result.status, result.stderr || result.stdout).toBe(0);
}, 25_000);
