import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const workflow = readFileSync(
  join(repositoryRoot, ".github/workflows/ci.yml"),
  "utf8",
);
const pathFilters = readFileSync(
  join(repositoryRoot, "scripts/ci-detect-changes.sh"),
  "utf8",
);

const railwayServices = [
  { service: "Web", config: "web", restartPolicy: "ALWAYS" },
  { service: "Operations Web", config: "operations-web", restartPolicy: "ALWAYS" },
  { service: "Gateway", config: "gateway", restartPolicy: "ALWAYS" },
  { service: "App View", config: "appview", restartPolicy: "ALWAYS" },
  { service: "Charybdis", config: "charybdis", restartPolicy: "ALWAYS" },
  { service: "Jetstream V2 Ingest", config: "jetstream-ingest", restartPolicy: "ALWAYS" },
  { service: "Ops", config: "operations", restartPolicy: "ALWAYS" },
  { service: "Database Migrator", config: "database-migrator", restartPolicy: "NEVER" },
] as const;

describe("CI workflow configuration", () => {
  it("matches the independently deployed Railway services", () => {
    expect(workflow).toContain("branches: [main, dev]");

    for (const job of [
      "web",
      "operations-web",
      "gateway",
      "appview",
      "charybdis",
      "operations",
      "jetstream-ingest",
      "database-migrator",
    ]) {
      expect(workflow).toContain(`  ${job}:`);
    }
  });

  it("keeps package checks and one required aggregate gate", () => {
    expect(workflow).toContain("  lexicons:");
    expect(workflow).toContain("  spec:");
    expect(workflow).toContain("  required:");
    expect(workflow).toContain("name: CI — Required");
  });

  it("leaves deployments to the platform integration", () => {
    expect(workflow).toContain("Railway deploys from its GitHub integration");
    expect(
      existsSync(join(repositoryRoot, ".github/workflows/deploy.yml")),
    ).toBe(false);
  });

  it("checks in Railway config-as-code for every deployed service", () => {
    const deploymentReadme = readFileSync(
      join(repositoryRoot, "railway/README.md"),
      "utf8",
    );

    for (const { service, config: configName, restartPolicy } of railwayServices) {
      const path = join(repositoryRoot, "railway", `${configName}.json`);
      expect(existsSync(path)).toBe(true);

      const config = JSON.parse(readFileSync(path, "utf8")) as {
        $schema?: string;
        build?: {
          builder?: string;
          dockerfilePath?: string;
          watchPatterns?: string[];
        };
        deploy?: { restartPolicyType?: string };
      };
      expect(config.$schema).toBe("https://railway.com/railway.schema.json");
      expect(["RAILPACK", "DOCKERFILE"]).toContain(config.build?.builder);
      expect(config.build?.watchPatterns).toContain(
        `/railway/${configName}.json`,
      );
      if (config.build?.builder === "DOCKERFILE") {
        expect(config.build.dockerfilePath).toMatch(/^\/services\//);
      }
      expect(config.deploy?.restartPolicyType).toBe(restartPolicy);
      expect(deploymentReadme).toContain(
        `| ${service} | \`/railway/${configName}.json\` |`,
      );

      const filterName = configName.replace("-", "_");
      const filter = pathFilters
        .split("\n\n")
        .find((block) =>
          block.startsWith(`filter_changed ${filterName} `),
        );
      expect(filter).toBeDefined();
      for (const watchPattern of config.build?.watchPatterns ?? []) {
        expect(filter ?? "").toContain(`'${watchPattern.slice(1)}'`);
      }
    }
  });

  it("uses the same service names in path detection", () => {
    for (const filter of [
      "web",
      "operations_web",
      "gateway",
      "appview",
      "charybdis",
      "operations",
      "jetstream_ingest",
      "database_migrator",
      "lexicons",
      "spec",
    ]) {
      expect(pathFilters).toContain(`filter_changed ${filter}`);
    }
  });
});
