import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createRailwayContext, project, type BucketNode, type ServiceNode } from "railway/iac";
import graph, { partial } from "../../../.railway/railway";

const root = join(import.meta.dir, "../../..");
const plan = (environmentName: string) => graph(createRailwayContext({ environmentName }), project);
const existing = ["Ingress Controller", "Projection Pool", "Coordinator"];

describe("Development podcast deployment graph", () => {
  it("adds a private bucket and one worker to Development while preserving the partial", async () => {
    const development = await plan("dev");
    expect(partial).toBe("indexing-consolidation");
    expect(development.resources?.map((resource) => resource.name)).toEqual([
      ...existing, "Podcast Media", "Podcast Media Worker",
    ]);
    const media = development.resources!.find((resource) => resource.name === "Podcast Media") as BucketNode;
    expect(media.type).toBe("bucket");
    expect(media.config).toEqual({ region: "sjc" });
    const worker = development.resources!.find((resource) => resource.name === "Podcast Media Worker") as ServiceNode;
    expect(worker.source).toEqual({ type: "github", repo: "Stygian-Tech/the-social-wire", branch: "dev", rootDirectory: "/" });
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
    expect(worker.variables?.APP_ENV).toEqual({ type: "literal", value: "dev" });
    expect(worker.variables?.PODCASTS_ENABLED).toEqual({ type: "literal", value: "true" });
    expect(worker.variables?.PODCAST_PUBLIC_GATEWAY_URL).toEqual({ type: "literal", value: "https://api.testing.thesocialwire.app" });
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

  it("smoke-tests the runtime executable and real database gate after building the image", () => {
    const workflow = readFileSync(join(root, ".github/workflows/ci.yml"), "utf8");
    const job = workflow.slice(workflow.indexOf("  podcast-worker:"), workflow.indexOf("  required:"));
    expect(job).toContain("Smoke test runtime entrypoint and database gate");
    expect(job).toContain("test -x /usr/local/bin/bun && /usr/local/bin/bun --version");
    expect(job).toContain("--env APP_ENV=dev the-social-wire-podcast-worker:test");
    expect(job).toContain("schema readiness requires DATABASE_URL");
    expect(job).toContain("absolute application path");
    expect(job.indexOf("Smoke test runtime entrypoint")).toBeGreaterThan(job.indexOf("Build runtime image"));
  });

  it("does not provision or enable any podcast resource in Production", async () => {
    const production = await plan("production");
    expect(production.resources?.map((resource) => resource.name)).toEqual(existing);
    for (const resource of production.resources! as ServiceNode[]) {
      expect(Object.keys(resource.variables ?? {}).some((name) => name.startsWith("PODCAST"))).toBe(false);
    }
  });

  it("rejects unrecognized environments instead of omitting owned resources", async () => {
    expect(() => plan("preview")).toThrow("authorized only for Development and Production");
  });
});
