import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const databaseClientConfigs = [
  "services/gateway/fly.toml",
  "services/gateway/fly.prod.toml",
  "services/appview/fly.toml",
  "services/appview/fly.prod.toml",
  "services/appview-worker/fly.toml",
  "services/appview-worker/fly.prod.toml",
  "services/operations/fly.toml",
  "services/operations/fly.prod.toml",
];

describe("Postgres connection budgets", () => {
  it("keeps every Fly database client below the shared Supabase session limit", () => {
    for (const path of databaseClientConfigs) {
      const config = readFileSync(join(repositoryRoot, path), "utf8");
      expect(config).toContain("POSTGRES_MAX_CONNECTIONS = '2'");
    }
  });
});
