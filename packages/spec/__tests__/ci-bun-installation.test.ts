import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "../../..");
const source = readFileSync(join(root, ".github/workflows/ci.yml"), "utf8");
const ci = Bun.YAML.parse(source) as any;

describe("Bounded CI dependency installation", () => {
  it("uses one frozen-install recovery helper for every Bun installation", () => {
    const installJobs = Object.entries(ci.jobs).filter(([, job]: any) => job.steps?.some((step: any) => step.name === "Install dependencies"));
    const expected = ["lexicons", "operations-web", "spec", "web"];
    if (ci.jobs["podcast-worker"]) expected.push("podcast-worker");
    expect(installJobs.map(([name]) => name).sort()).toEqual(expected.sort());
    for (const [, job] of installJobs as any) {
      expect(job.steps.filter((step: any) => step.name === "Install dependencies").map((step: any) => step.run)).toEqual(["bash scripts/ci/install-bun.sh"]);
      expect(job.steps.find((step: any) => step.name === "Cache Bun downloads").with.key).toContain("-bun-1.3.14-v2-");
    }
    expect(source).not.toContain("run: bun install");
  });
  it("runs hermetic retry tests in the always-required changes job", () => {
    expect(ci.jobs.changes.steps.some((step: any) => step.run === "node --test scripts/ci/install-bun.test.mjs")).toBe(true);
    expect(ci.jobs.required.needs).toContain("changes");
  });
});
