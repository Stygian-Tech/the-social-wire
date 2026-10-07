import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "../../..");
const read = (path: string) => readFileSync(join(root, path), "utf8");

describe("Ingress repository-local Go image dependencies", () => {
  it("resolves the local module before downloading and building either executable", () => {
    expect(read("services/jetstream-ingest/go.mod")).toContain("=> ../../packages/go");
    const dockerfile = read("services/jetstream-ingest/Dockerfile");
    const manifests = dockerfile.indexOf("COPY packages/go/go.mod packages/go/go.sum /src/packages/go/");
    const download = dockerfile.indexOf("RUN go mod download");
    const sources = dockerfile.indexOf("COPY packages/go /src/packages/go");
    expect(manifests).toBeGreaterThanOrEqual(0);
    expect(download).toBeGreaterThan(manifests);
    expect(sources).toBeGreaterThan(download);
    for (const executable of ["jetstream-ingest", "schema-ready"]) {
      const build = dockerfile.indexOf(`./cmd/${executable}`);
      expect(build).toBeGreaterThan(sources);
    }
  });

  for (const service of ["jetstream-ingest", "wire-jetstream-ingest"]) {
    it(`${service} rebuilds for changes to imported shared Go source`, () => {
      const config = JSON.parse(read(`railway/${service}.json`));
      expect(config.build.dockerfilePath).toBe("/services/jetstream-ingest/Dockerfile");
      expect(config.build.watchPatterns).toContain("/packages/go/**");
    });
  }

  it("includes the same dependency in consolidated Ingress IaC", () => {
    const iac = read(".railway/railway.ts");
    const ingress = iac.slice(iac.indexOf('const ingressController = service('), iac.indexOf('const projectionPool = service('));
    expect(ingress).toContain('"/packages/go/**"');
  });
});
