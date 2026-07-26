import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const REPO_ROOT = join(import.meta.dir, "../../..");

function flyConfig(path: string): string {
  return readFileSync(join(REPO_ROOT, path), "utf8");
}

describe("Operations recovery deployment config", () => {
  it("enables recovery in both testing services", () => {
    const operations = flyConfig("services/operations/fly.toml");
    const worker = flyConfig("services/appview-worker/fly.toml");

    expect(operations).toContain("OPERATIONS_RECOVERY_ENABLED = 'true'");
    expect(worker).toContain("OPERATIONS_RECOVERY_ENABLED = 'true'");
  });

  it("keeps recovery disabled in both production services", () => {
    const operations = flyConfig("services/operations/fly.prod.toml");
    const worker = flyConfig("services/appview-worker/fly.prod.toml");

    expect(operations).toContain("OPERATIONS_RECOVERY_ENABLED = 'false'");
    expect(worker).toContain("OPERATIONS_RECOVERY_ENABLED = 'false'");
  });
});
