import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const deployScript = readFileSync(
  join(repositoryRoot, "scripts/fly-deploy-operations.sh"),
  "utf8"
);
const continuousIntegration = readFileSync(
  join(repositoryRoot, ".github/workflows/ci.yml"),
  "utf8"
);
const manualDeploy = readFileSync(
  join(repositoryRoot, ".github/workflows/deploy.yml"),
  "utf8"
);
const databaseClients = new Map([
  ["services/gateway/fly.toml", 2],
  ["services/gateway/fly.prod.toml", 2],
  ["services/appview/fly.toml", 2],
  ["services/appview/fly.prod.toml", 8],
  ["services/appview-worker/fly.toml", 2],
  ["services/appview-worker/fly.prod.toml", 2],
  ["services/operations/fly.toml", 2],
  ["services/operations/fly.prod.toml", 2],
]);

describe("Operations deployment database configuration", () => {
  it("stages the canonical database URL before deploying Operations", () => {
    expect(deployScript).toContain("Missing SUPABASE_DATABASE_URL.");
    expect(deployScript).toContain(
      'flyctl secrets set --stage --app "$APP" "SUPABASE_DATABASE_URL=$SUPABASE_DATABASE_URL"'
    );
  });

  it("does not deploy to the retired Fly or Supabase development projects", () => {
    expect(continuousIntegration).not.toContain("supabase-push-dev:");
    expect(continuousIntegration).not.toContain("deploy-operations:");
    expect(continuousIntegration).not.toContain("SUPABASE_DEV_DATABASE_URL");
  });

  it("keeps manual Fly deploys production-only", () => {
    expect(manualDeploy).toContain(
      "SUPABASE_DATABASE_URL: ${{ secrets.SUPABASE_PROD_DATABASE_URL }}"
    );
    expect(manualDeploy).not.toContain("SUPABASE_DEV_DATABASE_URL");
    expect(manualDeploy).not.toContain("inputs.branch");
    expect(manualDeploy).toContain("fly-deploy-operations.sh main");
  });

  it("budgets Fly connection pools below the shared Supabase session limit", () => {
    for (const [path, connections] of databaseClients) {
      const config = readFileSync(join(repositoryRoot, path), "utf8");
      expect(config).toContain(
        `POSTGRES_MAX_CONNECTIONS = '${connections}'`
      );
    }
  });
});
