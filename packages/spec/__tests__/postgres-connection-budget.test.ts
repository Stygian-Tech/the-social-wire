import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const databaseClientConfigs = new Map([
  ["services/gateway/fly.toml", 2],
  ["services/gateway/fly.prod.toml", 2],
  ["services/appview/fly.toml", 2],
  ["services/appview/fly.prod.toml", 8],
  ["services/appview-worker/fly.toml", 2],
  ["services/appview-worker/fly.prod.toml", 2],
  ["services/operations/fly.toml", 2],
  ["services/operations/fly.prod.toml", 2],
]);

describe("Postgres connection budgets", () => {
  it("keeps every Fly database client below the shared Supabase session limit", () => {
    for (const [path, connections] of databaseClientConfigs) {
      const config = readFileSync(join(repositoryRoot, path), "utf8");
      expect(config).toContain(
        `POSTGRES_MAX_CONNECTIONS = '${connections}'`
      );
    }
  });
});
