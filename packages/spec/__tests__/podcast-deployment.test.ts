import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { createRailwayContext, project, type BucketNode, type ServiceNode } from "railway/iac";
import graph, { partial } from "../../../.railway/railway";

const root = join(import.meta.dir, "../../..");
const plan = (environmentName: string) => graph(createRailwayContext({ environmentName }), project);
const existing = ["Ingress Controller", "Projection Pool", "Coordinator"];

describe("Podcast deployment graph", () => {
  it("copies workspace file dependencies before the frozen install", () => {
    const dockerfile = readFileSync(join(root, "services/podcast-worker/Dockerfile"), "utf8");
    const beforeInstall = dockerfile.split("RUN bun install --frozen-lockfile")[0]!;
    const copies = [...beforeInstall.matchAll(/^COPY (\S+) (\S+)$/gm)];
    const sources = copies.map((copy) => copy[1]!);
    const manifests = sources.filter((source) => source.endsWith("/package.json"));
    expect(manifests.length).toBeGreaterThan(0);
    for (const manifest of manifests) {
      const pkg = JSON.parse(readFileSync(join(root, manifest), "utf8"));
      for (const dependencies of [pkg.dependencies, pkg.devDependencies, pkg.optionalDependencies]) {
        for (const dependency of Object.values(dependencies ?? {})) {
          if (typeof dependency !== "string" || !dependency.startsWith("file:")) continue;
          const target = relative(root, resolve(root, manifest, "..", dependency.slice(5)));
          expect(existsSync(join(root, target))).toBe(true);
          expect(sources.some((source) => target === source || target.startsWith(`${source}/`))).toBe(true);
        }
      }
    }
  });

  it.each([
    { environment: "dev", appEnvironment: "dev", branch: "dev", gateway: "https://api.testing.thesocialwire.app" },
    { environment: "production", appEnvironment: "prod", branch: "main", gateway: "https://api.thesocialwire.app" },
  ])("provisions private podcast resources with the correct $environment contract", async ({ environment, appEnvironment, branch, gateway }) => {
    const deployment = await plan(environment);
    const bucketName = environment === "production" ? "Podcast Media Production" : "Podcast Media";
    expect(partial).toBe("indexing-consolidation");
    expect(deployment.resources?.map((resource) => resource.name)).toEqual([
      ...existing, bucketName, "Podcast Media Worker",
    ]);
    const media = deployment.resources!.find((resource) => resource.name === bucketName) as BucketNode;
    expect(media.type).toBe("bucket");
    expect(media.config).toEqual({ region: "sjc" });
    const worker = deployment.resources!.find((resource) => resource.name === "Podcast Media Worker") as ServiceNode;
    expect(worker.source).toEqual({ type: "github", repo: "Stygian-Tech/the-social-wire", branch, rootDirectory: "/" });
    expect(worker.configFile).toBeUndefined();
    expect(worker.networking).toBeUndefined();
    expect(worker.deploy).toEqual({
      healthcheckPath: "/startupz", healthcheckTimeout: 120, restartPolicyType: "ALWAYS",
      multiRegionConfig: { sfo: { numReplicas: 1 } },
    });
    expect(worker.build?.dockerfilePath).toBe("/services/podcast-worker/Dockerfile");
    for (const path of ["/.railway/**", "/services/podcast-worker/**", "/database/migrations/**", "/services/jetstream-ingest/cmd/schema-ready/**", "/services/jetstream-ingest/internal/schemaready/**", "/services/jetstream-ingest/go.mod", "/services/jetstream-ingest/go.sum", "/package.json", "/bun.lock"]) {
      expect(worker.build?.watchPatterns).toContain(path);
    }
    expect(worker.variables?.APP_ENV).toEqual({ type: "literal", value: appEnvironment });
    expect(worker.variables?.PODCASTS_ENABLED).toEqual({ type: "literal", value: "true" });
    expect(worker.variables?.PODCAST_BRIDGE_ENABLED).toEqual({ type: "literal", value: "false" });
    expect(worker.variables?.PODCAST_PUBLIC_GATEWAY_URL).toEqual({ type: "literal", value: gateway });
    for (const variable of ["DATABASE_URL", "DATABASE_MIGRATOR_SERVICE_ID", "PODCAST_MEDIA_INTERNAL_SECRET", "PODCAST_BRIDGE_DID", "PODCAST_BRIDGE_PDS_URL", "PODCAST_BRIDGE_IDENTIFIER", "PODCAST_BRIDGE_APP_PASSWORD"]) {
      expect(worker.variables?.[variable]).toEqual({ type: "preserve" });
    }
    for (const [variable, output] of Object.entries({ PODCAST_S3_ENDPOINT: "ENDPOINT", PODCAST_S3_BUCKET: "BUCKET", PODCAST_S3_REGION: "REGION", PODCAST_S3_ACCESS_KEY_ID: "ACCESS_KEY_ID", PODCAST_S3_SECRET_ACCESS_KEY: "SECRET_ACCESS_KEY" })) {
      expect(worker.variables?.[variable]).toEqual({ type: "reference", resource: media.address, output });
    }
    expect(existsSync(join(root, "railway/podcast-worker.json"))).toBe(false);
    const dockerfile = readFileSync(join(root, "services/podcast-worker/Dockerfile"), "utf8");
    expect(dockerfile).toContain('ENTRYPOINT ["/usr/local/bin/schema-ready", "--", "/usr/local/bin/bun", "services/podcast-worker/src/index.ts"]');
  });

  it("tests the source entrypoint database gate without building a deployment image", () => {
    const workflow = readFileSync(join(root, ".github/workflows/ci.yml"), "utf8");
    const job = workflow.slice(workflow.indexOf("  podcast-worker:"), workflow.indexOf("  required:"));
    expect(job).toContain("Test source entrypoint database gate");
    expect(job).toContain('go build -o "$RUNNER_TEMP/schema-ready-test" ./cmd/schema-ready');
    expect(job).toContain("env -u DATABASE_URL APP_ENV=dev");
    expect(job).toContain("schema readiness requires DATABASE_URL");
    expect(job).toContain("absolute application path");
    expect(job).not.toContain("docker build");
    expect(job).toContain("bun --cwd services/podcast-worker typecheck");
    expect(job).toContain("bun --cwd services/podcast-worker test");
  });

  it.each(["dev", "production"])("keeps podcast variables out of indexing services in %s", async (environment) => {
    const deployment = await plan(environment);
    for (const resource of deployment.resources!.filter((resource) => existing.includes(resource.name)) as ServiceNode[]) {
      expect(Object.keys(resource.variables ?? {}).some((name) => name.startsWith("PODCAST"))).toBe(false);
    }
  });

  it("rejects unrecognized environments instead of omitting owned resources", async () => {
    expect(() => plan("preview")).toThrow("authorized only for Development and Production");
  });
});
