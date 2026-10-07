import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const root = join(import.meta.dir, "../../..");
const text = readFileSync(join(root, ".github/workflows/validated-merge.yml"), "utf8");
const workflow = Bun.YAML.parse(text) as any;

describe("Production merged commit verification", () => {
  it("creates a push-main read-only check suite without changing the protected PR gate", () => {
    expect(workflow.on).toEqual({ push: { branches: ["main"] } });
    expect(workflow.permissions).toEqual({ contents: "read", "pull-requests": "read", checks: "read", actions: "read" });
    expect(Object.keys(workflow.jobs)).toEqual(["verify"]);
    expect(workflow.jobs.verify.name).toBe("Production — Validated Merge");
    expect(workflow.jobs.verify["timeout-minutes"]).toBe(3);
    expect(workflow.concurrency["cancel-in-progress"]).toBe(false);
    const steps = workflow.jobs.verify.steps;
    expect(steps.find((step: any) => step.uses === "actions/checkout@v6").with["persist-credentials"]).toBe(false);
    expect(steps.filter((step: any) => step.run).map((step: any) => step.run)).toEqual(["node scripts/ci/validated-merge.mjs"]);
    expect(text).not.toMatch(/docker build|go build|next build|railway up|gh pr merge|permissions: write/);
  });
  it("tests the verifier before the existing required path-filtered checks", () => {
    const ci = Bun.YAML.parse(readFileSync(join(root, ".github/workflows/ci.yml"), "utf8")) as any;
    expect(ci.jobs.changes.steps.some((step: any) => step.run === "node --test scripts/ci/validated-merge.test.mjs")).toBe(true);
    expect(ci.jobs.changes.steps.filter((step: any) => step.run === "node scripts/ci/validated-merge.mjs --receipt")).toHaveLength(1);
    expect(ci.jobs.required.needs).toContain("changes");
    expect(ci.jobs.required.name).toBe("CI — Required");
    expect(ci.on).toHaveProperty("pull_request");
    expect(ci.on).not.toHaveProperty("push");
  });
});
