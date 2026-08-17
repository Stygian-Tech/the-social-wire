import { afterEach, describe, expect, it } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { execFileSync } from "node:child_process";

const repositoryRoot = join(import.meta.dir, "../../..");
const detector = join(repositoryRoot, "scripts/ci-detect-changes.sh");
const temporaryRepositories: string[] = [];

afterEach(() => {
  for (const path of temporaryRepositories.splice(0)) {
    rmSync(path, { recursive: true, force: true });
  }
});

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function repositoryWithChange(path: string): {
  cwd: string;
  base: string;
  head: string;
} {
  const cwd = mkdtempSync(join(tmpdir(), "socialwire-ci-paths-"));
  temporaryRepositories.push(cwd);
  git(cwd, "init", "--initial-branch=main");
  git(cwd, "config", "user.name", "CI Test");
  git(cwd, "config", "user.email", "ci@example.invalid");
  git(cwd, "config", "commit.gpgsign", "false");
  writeFileSync(join(cwd, "README.md"), "base\n");
  mkdirSync(join(cwd, dirname(path)), { recursive: true });
  writeFileSync(join(cwd, path), "before\n");
  git(cwd, "add", ".");
  git(cwd, "commit", "-m", "base");
  const base = git(cwd, "rev-parse", "HEAD");
  writeFileSync(join(cwd, path), "after\n");
  git(cwd, "add", ".");
  git(cwd, "commit", "-m", "change");
  return { cwd, base, head: git(cwd, "rev-parse", "HEAD") };
}

function detect(
  repository: ReturnType<typeof repositoryWithChange>,
  eventName: "push" | "pull_request",
  before = repository.base,
): Map<string, string> {
  const output = join(repository.cwd, "github-output.txt");
  execFileSync("bash", [detector], {
    cwd: repository.cwd,
    env: {
      ...process.env,
      GITHUB_BASE_REF: "",
      GITHUB_EVENT_BEFORE: eventName === "push" ? before : "",
      GITHUB_EVENT_NAME: eventName,
      GITHUB_EVENT_PULL_REQUEST_BASE_SHA:
        eventName === "pull_request" ? repository.base : "",
      GITHUB_OUTPUT: output,
      GITHUB_SHA: repository.head,
    },
  });
  return new Map(
    readFileSync(output, "utf8")
      .trim()
      .split("\n")
      .map((line) => line.split("=", 2) as [string, string]),
  );
}

describe("CI path detection", () => {
  it("uses the push before SHA instead of running the full matrix", () => {
    const result = detect(repositoryWithChange("docs/wiki/Testing.md"), "push");
    expect(result.get("docs")).toBe("true");
    expect(result.get("web")).toBe("false");
    expect(result.get("gateway")).toBe("false");
  });

  it("maps Apple changes to Apple and cross-client contract checks", () => {
    const result = detect(
      repositoryWithChange("apps/apple/SocialWire/Feature.swift"),
      "pull_request",
    );
    expect(result.get("apple")).toBe("true");
    expect(result.get("spec")).toBe("true");
    expect(result.get("web")).toBe("false");
  });

  it("runs database checks without an extra Charybdis job for migrations", () => {
    const result = detect(
      repositoryWithChange("database/migrations/20990101000000_example.sql"),
      "pull_request",
    );
    expect(result.get("charybdis")).toBe("false");
    expect(result.get("jetstream_ingest")).toBe("true");
    expect(result.get("database_migrator")).toBe("true");
    expect(result.get("spec")).toBe("true");
  });

  it("runs deterministic spec coverage when the migration runner changes", () => {
    const result = detect(
      repositoryWithChange("scripts/apply-database-migrations.sh"),
      "pull_request",
    );
    expect(result.get("database_migrator")).toBe("true");
    expect(result.get("spec")).toBe("true");
    expect(result.get("charybdis")).toBe("false");
  });

  it("runs both Bun coverage jobs when their shared inventory gate changes", () => {
    const result = detect(
      repositoryWithChange("scripts/check-bun-coverage-inventory.ts"),
      "pull_request",
    );
    expect(result.get("web")).toBe("true");
    expect(result.get("operations_web")).toBe("true");
    expect(result.get("gateway")).toBe("false");
  });

  it("runs scope-policy drift checks for Jetstream admission changes", () => {
    const result = detect(
      repositoryWithChange("services/jetstream-ingest/internal/store/postgres.go"),
      "pull_request",
    );
    expect(result.get("jetstream_ingest")).toBe("true");
    expect(result.get("spec")).toBe("true");
    expect(result.get("charybdis")).toBe("false");
  });

  it("runs the retired-generation policy spec when its runbook changes", () => {
    const result = detect(
      repositoryWithChange(
        "docs/runbooks/operations/jetstream-v2-durable-replay.md",
      ),
      "pull_request",
    );
    expect(result.get("spec")).toBe("true");
    expect(result.get("operations_web")).toBe("true");
    expect(result.get("charybdis")).toBe("false");
  });

  it("runs the full matrix when the detector changes", () => {
    const result = detect(
      repositoryWithChange("scripts/ci-detect-changes.sh"),
      "pull_request",
    );
    expect([...result.values()].every((value) => value === "true")).toBe(true);
  });

  it("runs the full matrix for an initial push without a base commit", () => {
    const result = detect(
      repositoryWithChange("README.md"),
      "push",
      "0000000000000000000000000000000000000000",
    );
    expect([...result.values()].every((value) => value === "true")).toBe(true);
  });
});
