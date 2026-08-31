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
const railwayInfrastructure = readFileSync(
  join(repositoryRoot, ".railway/railway.ts"),
  "utf8",
);

const railwayServices = [
  { service: "Web", config: "web", restartPolicy: "ALWAYS" },
  { service: "Operations Web", config: "operations-web", restartPolicy: "ALWAYS" },
  { service: "Gateway", config: "gateway", restartPolicy: "ALWAYS" },
  { service: "App View", config: "appview", restartPolicy: "ALWAYS" },
  { service: "Charybdis", config: "charybdis", restartPolicy: "ALWAYS" },
  { service: "Jetstream V2 Ingest", config: "jetstream-ingest", restartPolicy: "ALWAYS" },
  { service: "The Wire Global Ingest", config: "wire-jetstream-ingest", restartPolicy: "ALWAYS" },
  { service: "The Wire Worker", config: "wire-worker", restartPolicy: "ALWAYS" },
  { service: "The Wire Inbox Drain", config: "wire-inbox-drain", restartPolicy: "ALWAYS" },
  { service: "The Wire Corpus Edge", config: "wire-corpus-edge", restartPolicy: "ALWAYS" },
  { service: "Ops", config: "operations", restartPolicy: "ALWAYS" },
  { service: "Database Migrator", config: "database-migrator", restartPolicy: "NEVER" },
] as const;

describe("CI workflow configuration", () => {
  it("matches the independently deployed Railway services", () => {
    expect(workflow).toContain("branches: [main, dev]");

    for (const job of [
      "web",
      "operations-web",
      "apple",
      "gateway",
      "appview",
      "charybdis",
      "operations",
      "jetstream-ingest",
      "wire-ingest",
      "wire-worker",
      "indexing-worker",
      "wire-corpus-edge",
      "database-migrator",
      "docs",
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

  it("tests merge previews once and supports merge queues", () => {
    const triggerBlock = workflow.slice(0, workflow.indexOf("\nenv:"));
    expect(triggerBlock).toContain("pull_request:");
    expect(triggerBlock).toContain("merge_group:");
    expect(triggerBlock).toContain("workflow_dispatch:");
    expect(triggerBlock).not.toContain("push:");
  });

  it("passes event SHAs into path detection and enforces coverage", () => {
    expect(workflow).toContain("GITHUB_EVENT_BEFORE: ${{ github.event.before }}");
    expect(workflow).toContain("GITHUB_EVENT_PULL_REQUEST_BASE_SHA:");
    expect(workflow).toContain("bun --cwd apps/web run test:coverage");
    expect(workflow).toContain("bun --cwd apps/operations run test:coverage");
    expect(workflow).toContain("go test -race -coverprofile=");
  });

  it("pins the latest production-supported Node.js LTS in JavaScript jobs", () => {
    expect(workflow).toContain('NODE_VERSION: "24.19.0"');
    expect(workflow).toContain("FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true");
    expect(workflow.match(/uses: actions\/setup-node@v6/g)).toHaveLength(4);
    expect(workflow.match(/node-version: \$\{\{ env\.NODE_VERSION \}\}/g)).toHaveLength(
      4,
    );
  });

  it("tests deployment-shaped artifacts and migrations", () => {
    expect(workflow).toContain("Build Gateway production image");
    expect(workflow).toContain("Build AppView production image");
    expect(workflow).toContain("Build Charybdis production image");
    expect(workflow).toContain("Build The Wire worker production image");
    expect(workflow).toContain("Build replicated indexing production image");
    expect(workflow).toContain("Build The Wire Corpus Edge production image");
    expect(workflow).toContain("Build Operations production image");
    expect(workflow).toContain("Apply migrations from empty and verify idempotence");
    expect(workflow).toContain("Test iOS app with coverage");
  });

  it("leaves deployments to the platform integration", () => {
    expect(workflow).toContain(
      "Railway deploys protected branch merges from its GitHub integration",
    );
    expect(
      existsSync(join(repositoryRoot, ".github/workflows/deploy.yml")),
    ).toBe(false);
  });

  it("keeps grandfathered Railway config-as-code for compatibility services", () => {
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
        deploy?: { healthcheckPath?: string; restartPolicyType?: string };
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
      if (["jetstream-ingest", "wire-jetstream-ingest", "wire-worker", "wire-inbox-drain", "charybdis"].includes(configName)) {
        expect(config.deploy?.healthcheckPath).toBe("/startupz");
      }
      expect(deploymentReadme).toContain(
        `| ${service} | \`/railway/${configName}.json\` |`,
      );

      const filterName = configName === "wire-jetstream-ingest"
          ? "wire_ingest"
          : configName === "wire-inbox-drain"
            ? "wire_worker"
            : configName.replaceAll("-", "_");
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

  it("owns consolidated indexing services through an environment-gated IaC partial", () => {
    expect(railwayInfrastructure).toContain(
      'export const partial = "indexing-consolidation";',
    );
    expect(railwayInfrastructure).toContain('context.isEnvironment("dev")');
    expect(railwayInfrastructure).toContain(
      'context.isEnvironment("production")',
    );
    expect(railwayInfrastructure).not.toContain(
      'return project("The Social Wire", { resources: [] });',
    );
    expect(railwayInfrastructure).toContain("throw new Error(");

    for (const serviceName of [
      "Ingress Controller",
      "Projection Pool",
      "Coordinator",
    ]) {
      expect(railwayInfrastructure).toContain(`service("${serviceName}"`);
    }

    expect(railwayInfrastructure).toContain(
      'dockerfilePath: "/services/jetstream-ingest/Dockerfile"',
    );
    expect(railwayInfrastructure).toContain(
      'dockerfilePath: "/services/indexing-worker/Dockerfile"',
    );
    expect(railwayInfrastructure).toContain('healthcheckPath: "/startupz"');
    expect(railwayInfrastructure).toContain('restartPolicyType: "ALWAYS"');
    expect(railwayInfrastructure).toContain(
      'JETSTREAM_WIRE_ADMISSION_RATE_PER_SECOND: "3"',
    );
    expect(railwayInfrastructure).toContain(
      'JETSTREAM_WIRE_ADMISSION_BURST_EVENTS: "1"',
    );
    expect(railwayInfrastructure).toContain(
      'JETSTREAM_WIRE_LANES: "external,publication"',
    );
    expect(railwayInfrastructure).toContain('WIRE_INBOX_CONCURRENCY: "52"');
    expect(railwayInfrastructure).toContain('workerRegion: "sfo"');
    expect(railwayInfrastructure).toContain('branch: "main"');
    const productionProfile = railwayInfrastructure.slice(
      railwayInfrastructure.indexOf("const productionProfile"),
      railwayInfrastructure.indexOf("const indexingBuild"),
    );
    expect(productionProfile).toContain(
      '"wire-global-v8-prod-external-live-v1"',
    );
    expect(productionProfile).toContain(
      '"wire-global-v8-prod-publication-live-tail-v1"',
    );
    expect(productionProfile).not.toContain("wire-global-v4-dev-live-20260830");
    expect(productionProfile).not.toContain("24790001258");
    expect(pathFilters.match(/'\.railway\/\*\*'/g)).toHaveLength(3);
  });

  it("uses the same service names in path detection", () => {
    for (const filter of [
      "web",
      "operations_web",
      "apple",
      "gateway",
      "appview",
      "charybdis",
      "operations",
      "jetstream_ingest",
      "wire_ingest",
      "wire_worker",
      "indexing_worker",
      "wire_corpus_edge",
      "database_migrator",
      "lexicons",
      "spec",
      "docs",
    ]) {
      expect(pathFilters).toContain(`filter_changed ${filter}`);
    }
  });
});
