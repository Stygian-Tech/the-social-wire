import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "../../..");
const read = (path: string) => readFileSync(join(root, path), "utf8");
const images = {
  "jetstream-ingest": "jetstream-ingest",
  "indexing-worker": "IndexingWorker",
  appview: "AppView",
  gateway: "Gateway",
  operations: "Operations",
  "appview-worker": "AppViewWorker",
  "wire-worker": "WireWorker",
};

describe("schema readiness deployment contract", () => {
  for (const [service, executable] of Object.entries(images)) {
    it(`${service} gates its existing executable with an image-owned manifest`, () => {
      const dockerfile = read(`services/${service}/Dockerfile`);
      const entrypoint = JSON.parse(dockerfile.match(/^ENTRYPOINT (.+)$/m)![1]);
      expect(entrypoint[0]).toBe("/usr/local/bin/schema-ready");
      expect(entrypoint.slice(-2)).toEqual(["--", `/usr/local/bin/${executable}`]);
      expect(entrypoint.includes("--allow-local-sqlite")).toBe(["gateway", "appview"].includes(service));
      expect(dockerfile).toContain("COPY database/migrations /src/database/migrations");
      expect(dockerfile).toContain("--generate-manifest /src/database/migrations");
      expect(dockerfile).toContain("/etc/socialwire/required-migrations.txt");
    });
  }

  for (const service of ["gateway", "appview", "operations", "charybdis", "jetstream-ingest", "wire-jetstream-ingest", "wire-worker", "wire-inbox-drain", "wire-fresh-inbox-drain"]) {
    it(`${service} rebuilds on schema/gate changes without bypassing the entrypoint`, () => {
      const config = JSON.parse(read(`railway/${service}.json`));
      expect(config.deploy.startCommand).toBeUndefined();
      expect(config.build.watchPatterns).toContain("/database/migrations/**");
      const watchesGate = config.build.watchPatterns.includes("/services/jetstream-ingest/**") ||
        ["/services/jetstream-ingest/cmd/schema-ready/**", "/services/jetstream-ingest/internal/schemaready/**", "/services/jetstream-ingest/go.mod", "/services/jetstream-ingest/go.sum"].every((path) => config.build.watchPatterns.includes(path));
      expect(watchesGate).toBe(true);
      expect(config.deploy.healthcheckTimeout).toBeGreaterThan(90);
    });
  }

  it("keeps the consolidated IaC entrypoint and rebuild dependencies", () => {
    const iac = read(".railway/railway.ts");
    expect(iac).not.toContain("startCommand:");
    expect(iac).toContain('"/services/jetstream-ingest/internal/schemaready/**"');
    expect(iac).toContain('"/services/jetstream-ingest/cmd/schema-ready/**"');
    expect(iac).toContain('"/database/migrations/**"');
  });

  it("does not gate migrators or the separately owned Corpus Edge schema", () => {
    for (const service of ["database-migrator", "wire-corpus-edge"]) {
      expect(read(`services/${service}/Dockerfile`)).not.toContain("schema-ready");
    }
  });
});
