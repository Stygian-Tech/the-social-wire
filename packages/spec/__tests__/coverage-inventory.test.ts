import { afterEach, describe, expect, it } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const checker = join(repositoryRoot, "scripts/check-bun-coverage-inventory.ts");
const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const path of temporaryDirectories.splice(0)) {
    rmSync(path, { recursive: true, force: true });
  }
});

function fixture(): string {
  const cwd = mkdtempSync(join(tmpdir(), "socialwire-coverage-inventory-"));
  temporaryDirectories.push(cwd);
  mkdirSync(join(cwd, "src"));
  writeFileSync(join(cwd, "src/covered.ts"), "export const covered = true;\n");
  writeFileSync(join(cwd, "src/missing.ts"), "export const missing = true;\n");
  writeFileSync(join(cwd, "lcov.info"), "TN:\nSF:src/covered.ts\nend_of_record\n");
  writeFileSync(join(cwd, "allowlist.txt"), "src/missing.ts\n");
  return cwd;
}

function check(cwd: string): string {
  return execFileSync(
    process.execPath,
    [checker, "src", "lcov.info", "allowlist.txt"],
    { cwd, encoding: "utf8" },
  );
}

describe("Bun coverage inventory", () => {
  it("accepts reviewed production modules missing from LCOV", () => {
    const cwd = fixture();
    writeFileSync(
      join(cwd, "lcov.info"),
      `TN:\nSF:${join(cwd, "src/covered.ts")}\nend_of_record\n`,
    );
    expect(check(cwd)).toContain("1/2 production modules");
  });

  it("fails when a new production module is absent from LCOV", () => {
    const cwd = fixture();
    writeFileSync(join(cwd, "src/new-module.ts"), "export const added = true;\n");
    expect(() => check(cwd)).toThrow("Production sources absent from LCOV");
  });

  it("fails when an allowlist entry becomes covered", () => {
    const cwd = fixture();
    writeFileSync(
      join(cwd, "lcov.info"),
      "TN:\nSF:src/covered.ts\nend_of_record\nTN:\nSF:src/missing.ts\nend_of_record\n",
    );
    expect(() => check(cwd)).toThrow("Stale coverage inventory allowlist entries");
  });
});
