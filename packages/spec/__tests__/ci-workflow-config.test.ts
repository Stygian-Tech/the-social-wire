import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

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
  { service: "Jetstream V2 Ingest", config: "jetstream-ingest", restartPolicy: "ALWAYS" },
  { service: "The Wire Global Ingest", config: "wire-jetstream-ingest", restartPolicy: "ALWAYS" },
  { service: "The Wire Corpus Edge", config: "wire-corpus-edge", restartPolicy: "ALWAYS" },
  { service: "Ops", config: "operations", restartPolicy: "ALWAYS" },
  { service: "Database Migrator", config: "database-migrator", restartPolicy: "NEVER" },
] as const;

describe("CI workflow configuration", () => {
  it("retires standalone Swift worker jobs while retaining API domain tests", () => {
    for (const name of ["charybdis", "wire-worker"]) {
      expect(workflow).not.toContain(`  ${name}:`);
      expect(workflow).not.toContain(`services/${name}/Package.swift`);
    }
    for (const path of ["packages/swift/ThinAppViewCore", "packages/swift/WireCore", "packages/swift/FinanceCore", "packages/swift/SportsCore"]) {
      expect(workflow).toContain(path);
    }
  });
  it("retires only Swift service commands while retaining all shared contract suites", () => {
    for (const service of ["gateway", "appview", "operations", "wire-corpus-edge"]) {
      expect(workflow).not.toMatch(new RegExp(`working-directory: services/${service}\\n\\s*(?:env:[\\s\\S]*?)?run: swift test`));
      expect(workflow).not.toContain(`services/${service}/.build`);
    }
    for (const core of ["GatewayCore", "OperationsCore", "ReadStateCore", "ThinAppViewCore", "WireCore", "FinanceCore", "SportsCore", "SocialWireRedis"]) {
      expect(workflow).toContain(`packages/swift/${core}`);
    }
    expect(workflow).toContain("--skip-build --no-parallel --filter");
    expect(workflow).toContain("Verify presentation-only read contract");
    expect(workflow).toContain("wire-corpus-serving-verifier-postgres.test.ts");
  });
  it("packages and watches Go domains in every deployed Finance and Sports consumer", () => {
    for (const image of ["indexing-worker", "appview", "wire-corpus-edge"]) {
      const dockerfile = readFileSync(join(repositoryRoot, `services/${image}/Dockerfile`), "utf8");
      expect(dockerfile).toMatch(/^FROM golang:/m);
      expect(dockerfile).not.toMatch(/^FROM swift:/m);
      expect(dockerfile).toMatch(/^COPY packages\/go\/? (?:\/src\/)?packages\/go\/?$/m);
    }
    for (const configName of ["appview", "wire-corpus-edge"]) {
      const config = JSON.parse(readFileSync(join(repositoryRoot, `railway/${configName}.json`), "utf8"));
      expect(config.build.watchPatterns).toContain("/packages/go/**");
      expect(config.build.watchPatterns).not.toContain("/packages/swift/FinanceCore/**");
      expect(config.build.watchPatterns).not.toContain("/packages/swift/SportsCore/**");
    }
    const indexingBuild = railwayInfrastructure.slice(railwayInfrastructure.indexOf("const indexingBuild"), railwayInfrastructure.indexOf("const longRunningDeploy"));
    expect(indexingBuild).toContain('"/packages/go/**"');
  });

  it("keeps Finance and Sports selection ingestion in Development's explicit collection override", () => {
    const developmentProfile = railwayInfrastructure.slice(
      railwayInfrastructure.indexOf("const developmentProfile"),
      railwayInfrastructure.indexOf("const productionWireLiveGenerations"),
    );
    const collections = developmentProfile.match(/JETSTREAM_APPVIEW_COLLECTIONS:\s*"([^"]+)"/)?.[1].split(",");
    expect(collections).toContain("app.thesocialwire.finance.selection");
    expect(collections).toContain("app.thesocialwire.sports.selection");
    expect(developmentProfile).toContain('appViewGeneration: "jetstream-v2-us-west-finance-sports-v1-20261003"');
    expect(developmentProfile).toContain('JETSTREAM_APPVIEW_SOURCE_GENERATION: "jetstream-v2-us-west-finance-sports-v1-20261003"');
    expect(developmentProfile).toContain('JETSTREAM_APPVIEW_HOST: "jetstream.us-west.bsky.network"');
    expect(developmentProfile).toContain('JETSTREAM_WIRE_ENABLED: "false"');
    expect(developmentProfile).toContain('JETSTREAM_WIRE_LANES: "publicationwest"');
    expect(developmentProfile).toContain('WIRE_INBOX_SOURCE_GENERATIONS: "wire-global-v6-dev-publication-finance-live-20261001"');
    expect(developmentProfile).toContain('JETSTREAM_WIRE_PUBLICATIONWEST_REPLAY_INCIDENT_BYTES: "4294967296"');
    expect(developmentProfile).toContain('JETSTREAM_WIRE_PUBLICATIONWEST_REPLAY_DAILY_BYTES: "4294967296"');
    expect(developmentProfile).toContain('JETSTREAM_WIRE_PUBLICATIONWEST_DATABASE_MAX_BYTES: "17179869184"');
    expect(developmentProfile).toContain('JETSTREAM_WIRE_PUBLICATIONWEST_INBOX_MAX_ROWS: "50000"');
    expect(developmentProfile).toContain('JETSTREAM_WIRE_PUBLICATIONWEST_REPLAY_SNAPSHOT_ONLY: "false"');
    const appViewCursor = developmentProfile.match(/JETSTREAM_APPVIEW_BOOTSTRAP_AFTER_SEQ: "(\d+)"/)?.[1];
    const publicationCursor = developmentProfile.match(/JETSTREAM_WIRE_PUBLICATIONWEST_BOOTSTRAP_AFTER_SEQ: "(\d+)"/)?.[1];
    expect(appViewCursor).toBe("26608279414");
    expect(publicationCursor).toBe("26512357203");
  });

  it("matches the independently deployed Railway services", () => {
    expect(workflow).toContain("branches: [main, dev]");

    for (const job of [
      "web",
      "operations-web",
      "apple",
      "shared-swift",
      "go-packages",
      "jetstream-ingest",
      "wire-ingest",
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

  it("requires Go package parity and PostgreSQL integration checks", () => {
    const parsed = Bun.YAML.parse(workflow) as {
      jobs: Record<string, { needs?: string[]; steps: { run?: string; env?: Record<string, string> }[] }>;
    };
    const job = parsed.jobs["go-packages"];
    expect(parsed.jobs.required.needs).toContain("go-packages");
    const commands = job.steps.map((step) => step.run ?? "").join("\n");
    expect(commands).toContain("go test -race -p 1 ./...");
    expect(commands).toContain("generate-contracts.py --check");
    expect(commands).toContain("verify-ranking-parity.sh");
    expect(commands).toContain("verify-edition-parity.sh");
    expect(commands).toContain("verify-domain-ranking-parity.sh");
    const integration = job.steps.find((step) => step.run?.includes("go test -race -p 1 ./..."))!;
    expect(integration.env?.SOCIALWIRE_GO_CORPUS_TEST_DATABASE_URL).toContain("127.0.0.1:5432/socialwire_go_test");
    for (const name of ["SOCIALWIRE_GO_TEST_DATABASE_URL", "SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL", "SOCIALWIRE_GO_CORPUS_TEST_DATABASE_URL", "SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL", "SOCIALWIRE_GO_READSTATE_TEST_DATABASE_URL", "SOCIALWIRE_GO_TOPICS_TEST_DATABASE_URL", "SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL"]) {
      expect(job.steps.some((step) => step.env?.[name])).toBe(true);
    }
    const gate = parsed.jobs.required.steps.find((step) => step.run)!;
    expect(gate.run).toContain('check "$GO_PACKAGES_FLAG" "$GO_PACKAGES_RESULT"');
  });

  it("enables podcast integration only for a complete branch-scoped schema", () => {
    const parsed = Bun.YAML.parse(workflow) as { jobs: Record<string, { steps: { name?: string; run?: string }[] }> };
    const step = parsed.jobs["go-packages"].steps.find(item => item.name === "Select branch-scoped podcast integration coverage")!;
    expect(step.run).toBeDefined();
    for (const count of [0, 1, 2]) {
      const root = mkdtempSync(join(tmpdir(), "tsw-ci-podcast-schema-"));
      try {
        mkdirSync(join(root, "database/migrations"), { recursive: true });
        const files = ["20261005010000_podcast_listener.sql", "20261006010000_private_podcast_subscriptions.sql"];
        for (const file of files.slice(0, count)) writeFileSync(join(root, "database/migrations", file), "");
        const envFile = join(root, "environment");
        writeFileSync(envFile, "");
        const run = spawnSync("bash", ["-c", step.run!], { cwd: root, env: { ...process.env, GITHUB_ENV: envFile }, encoding: "utf8" });
        expect(run.status).toBe(count === 1 ? 1 : 0);
        const output = readFileSync(envFile, "utf8");
        if (count === 2) expect(output).toContain("SOCIALWIRE_GO_PODCAST_TEST_DATABASE_URL=postgresql://");
        if (count === 0) expect(output).toBe("SOCIALWIRE_GO_PODCAST_TEST_DATABASE_URL=\n");
        if (count === 1) expect(output).toBe("");
      } finally { rmSync(root, { recursive: true, force: true }); }
    }
  });

  it("runs bounded benchmark tests with an isolated receipt fixture and requires success", () => {
    const parsed = Bun.YAML.parse(workflow) as {
      jobs: Record<string, {
        "timeout-minutes"?: number;
        needs?: string[];
        services?: Record<string, { image: string; ports: string[]; options: string }>;
        steps: { run?: string; env?: Record<string, string> }[];
      }>;
    };
    const tools = parsed.jobs["benchmark-tools"];
    expect(tools["timeout-minutes"]).toBe(5);
    expect(tools.services?.postgres.image).toBe("postgres:18-alpine");
    expect(tools.services?.postgres.ports).toEqual(["5432:5432"]);
    expect(tools.services?.postgres.options).toContain("pg_isready -U postgres -d postgres");
    expect(tools.steps.find((step) => step.env?.TSW_RECEIPT_TEST_ADMIN_URL)?.env?.TSW_RECEIPT_TEST_ADMIN_URL)
      .toBe("postgresql://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable");
    expect(tools.steps.some((step) => step.run ===
      "python3 -W error::ResourceWarning -m unittest discover -s scripts/benchmarks/tests")).toBe(true);
    expect(parsed.jobs.required.needs).toContain("benchmark-tools");
    const gate = parsed.jobs.required.steps.find((step) => step.run)!;
    const env: Record<string, string> = { ...process.env as Record<string, string>, CHANGES_RESULT: "success" };
    for (const key of Object.keys(gate.env ?? {})) {
      if (key.endsWith("_FLAG")) env[key] = "false";
      if (key.endsWith("_RESULT") && key !== "CHANGES_RESULT") env[key] = "skipped";
    }
    env.BENCHMARK_TOOLS_FLAG = "true";
    for (const result of ["skipped", "failure", "cancelled", "success"]) {
      env.BENCHMARK_TOOLS_RESULT = result;
      const run = spawnSync("bash", ["-c", gate.run!], { env, encoding: "utf8" });
      expect(run.status).toBe(result === "success" ? 0 : 1);
    }
  });

  it("fails the aggregate gate for every required check that does not succeed", () => {
    const parsed = Bun.YAML.parse(workflow) as { jobs: Record<string, { steps: Array<{ run?: string; env?: Record<string, string> }> }> };
    const gate = parsed.jobs.required.steps.find(step => step.run)!;
    const baseline: Record<string, string> = { CHANGES_RESULT: "success" };
    for (const key of Object.keys(gate.env!)) {
      if (key.endsWith("_FLAG")) baseline[key] = "false";
      if (key.endsWith("_RESULT") && key !== "CHANGES_RESULT") baseline[key] = "skipped";
    }
    for (const flag of Object.keys(baseline).filter(key => key.endsWith("_FLAG"))) {
      const resultKey = flag.replace(/_FLAG$/, "_RESULT");
      for (const result of ["failure", "cancelled", "skipped", "success"]) {
        const run = spawnSync("bash", ["-c", gate.run!], {
          env: { ...process.env, ...baseline, [flag]: "true", [resultKey]: result },
          encoding: "utf8",
        });
        expect(run.status).toBe(result === "success" ? 0 : 1);
      }
    }
    for (const result of ["failure", "cancelled", "skipped"]) {
      const run = spawnSync("bash", ["-c", gate.run!], { env: { ...process.env, ...baseline, CHANGES_RESULT: result }, encoding: "utf8" });
      expect(run.status).toBe(1);
    }
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

  it("tests source contracts without deployment artifact builds", () => {
    expect(workflow).not.toMatch(/bunx turbo build|next build/);
    expect(workflow).not.toMatch(/docker build --file services\//);
    expect(workflow).not.toContain("Build runtime image");
    expect(workflow).toContain("Apply migrations from empty and verify idempotence");
    expect(workflow).toContain("Test iOS app with coverage");
    expect(workflow).toContain("go test -race");
    expect(workflow).toContain("Test source entrypoint database gate");
    // PostgreSQL process-restart images are executable integration fixtures.
    expect(workflow).toContain("Verify PostgreSQL clean shutdown");
    expect(workflow).toContain("Build isolated PostgreSQL restart fixture");
  });

  it("shares canonical migration preparation while keeping databases isolated", () => {
    const parsed = Bun.YAML.parse(workflow) as { jobs: Record<string, { steps: Array<{ uses?: string; with?: Record<string, string> }> }> };
    const databases: string[] = [];
    for (const job of ["shared-swift", "go-packages", "jetstream-ingest", "wire-corpus-edge", "database-migrator"]) {
      const preparation = parsed.jobs[job].steps.filter(step => step.uses === "./.github/actions/prepare-postgres");
      expect(preparation).toHaveLength(1);
      databases.push(preparation[0].with!["database-url"]);
    }
    expect(new Set(databases).size).toBe(5);
    const migrationStep = parsed.jobs["database-migrator"].steps.find(step => step.uses === "./.github/actions/prepare-postgres");
    expect(migrationStep!.with!["verify-idempotence"]).toBe("true");
    const action = readFileSync(join(repositoryRoot, ".github/actions/prepare-postgres/action.yml"), "utf8");
    expect(action).toContain("bash scripts/ci-prepare-postgres.sh");
    expect(action).toContain("Preload telemetry statement statistics");
    expect(action).toContain("SELECT count(*) FROM pg_stat_statements");
    for (const job of ["shared-swift", "go-packages"]) {
      const preparation = parsed.jobs[job].steps.find(step => step.uses === "./.github/actions/prepare-postgres");
      expect(preparation!.with!["postgres-container"]).toBe("${{ job.services.postgres.id }}");
    }
  });

  it("leaves deployments to the platform integration", () => {
    expect(workflow).toContain(
      "Railway deploys protected branch merges from its GitHub integration",
    );
    expect(
      existsSync(join(repositoryRoot, ".github/workflows/deploy.yml")),
    ).toBe(false);
  });

  it("keeps canonical Railway config-as-code covered by required checks", () => {
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
      if (["jetstream-ingest", "wire-jetstream-ingest"].includes(configName)) {
        expect(config.deploy?.healthcheckPath).toBe("/startupz");
      }
      expect(deploymentReadme).toContain(
        `| ${service} | \`/railway/${configName}.json\` |`,
      );

      const filterName = ["gateway", "appview", "operations"].includes(configName)
          ? "go_packages"
          : configName === "wire-jetstream-ingest"
          ? "wire_ingest"
          : configName.replaceAll("-", "_");
      const filter = pathFilters
        .split("\n\n")
        .find((block) =>
          block.startsWith(`filter_changed ${filterName} `),
        );
      expect(filter).toBeDefined();
      for (const watchPattern of config.build?.watchPatterns ?? []) {
        const path = watchPattern.slice(1);
        const candidates = [filter, pathFilters.split("\n\n").find(block => block.startsWith("filter_changed go_packages "))].join("\n");
        const coveredBySharedSwift = path.startsWith("packages/swift/") && candidates.includes("'packages/swift/**'");
        const coveredByService = ["gateway", "appview", "operations", "wire-corpus-edge"].some(service => path.startsWith(`services/${service}/`) && candidates.includes(`'services/${service}/**'`));
        const coveredByGlob = [...candidates.matchAll(/'([^']+)'/g)].some(match => new Bun.Glob(match[1]).match(path));
        expect(candidates.includes(`'${path}'`) || coveredBySharedSwift || coveredByService || coveredByGlob).toBe(true);
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
    expect(railwayInfrastructure).toContain(
      'JETSTREAM_WIRE_PUBLICATIONWEST_REPLAY_CANARY_EXPIRES_AT: "2026-09-23T00:00:00Z"',
    );
    expect(railwayInfrastructure).toContain('"wire-global-v9-prod-publication-west-20260919"');
    expect(railwayInfrastructure).toContain('WIRE_INBOX_SOURCE_GENERATIONS: productionWireCoordinatorGenerations');
    expect(railwayInfrastructure).toContain('"wire-global-v8-prod-external-8d-snapshot-b-v1"');
    expect(railwayInfrastructure).toContain('JETSTREAM_WIRE_LANES: "publicationwest"');
    expect(railwayInfrastructure).toContain('WIRE_INBOX_CONCURRENCY: "52"');
    expect(railwayInfrastructure).toContain('workerRegion: "sfo"');
    expect(railwayInfrastructure).toContain('branch: "main"');
    const productionProfile = railwayInfrastructure.slice(
      railwayInfrastructure.indexOf("const productionProfile"),
      railwayInfrastructure.indexOf("const indexingBuild"),
    );
    const productionWireSourceGenerations = railwayInfrastructure.slice(
      railwayInfrastructure.indexOf("const productionWireLiveGenerations"),
      railwayInfrastructure.indexOf("const productionProfile"),
    );
    expect(productionWireSourceGenerations).toContain(
      '"wire-global-v8-prod-external-live-v1"',
    );
    expect(productionWireSourceGenerations).toContain(
      '"wire-global-v8-prod-publication-live-tail-v1"',
    );
    expect(productionProfile).toContain(
      '"wire-global-v8-prod-external-live-v1"',
    );
    expect(productionProfile).toContain(
      '"wire-global-v8-prod-publication-live-tail-v1"',
    );
    expect(productionProfile).toContain(
      '"wire-global-v9-prod-publication-west-20260919"',
    );
    expect(productionProfile).not.toContain("wire-global-v5-dev-publication-west-20260919");
    expect(productionProfile).not.toContain("wire-global-v4-dev-live-20260830");
    expect(productionProfile).not.toContain("24790001258");
    expect(pathFilters.match(/'\.railway\/\*\*'/g)).toHaveLength(4);
  });

  it("tests migrated Go entry points within the existing required gate", () => {
    expect(workflow).toContain("Test migrated Go service entry points");
    expect(workflow).toContain("services/wire-corpus-edge/go.sum");
    expect(workflow).toContain("for service in gateway appview operations wire-corpus-edge; do");
    expect(workflow).toContain('cd "services/$service"');
    expect(workflow).toContain("go test -race -p 1 ./...");
    expect(pathFilters).toContain("'services/*/go.mod'");
    expect(pathFilters).toContain("'services/*/go.sum'");
    expect(pathFilters).toContain("'services/*/cmd/**'");
    expect(pathFilters).toContain("'services/*/internal/**'");
  });

  it("uses the same service names in path detection", () => {
    for (const filter of [
      "web",
      "operations_web",
      "apple",
      "shared_swift",
            "go_packages",
      "jetstream_ingest",
      "wire_ingest",
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
