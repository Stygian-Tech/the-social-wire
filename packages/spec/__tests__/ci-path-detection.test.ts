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
  it("checks Go packages and worker contracts when shared Go code changes", () => {
    const result = detect(repositoryWithChange("packages/go/wirecore/ranker.go"), "pull_request");
    for (const job of ["go_packages", "indexing_worker", "jetstream_ingest", "wire_ingest"]) {
      expect(result.get(job)).toBe("true");
    }
  });

  it.each([
    "services/operations/cmd/operations/main.go",
    "services/operations/go.mod",
    "services/appview/internal/topics/routes.go",
    "services/gateway/go.sum",
    "services/wire-corpus-edge/go.mod",
    "services/wire-corpus-edge/go.sum",
    "services/wire-corpus-edge/internal/edge/handler_test.go",
    "services/wire-corpus-edge/cmd/wire-corpus-edge/main.go",
    "services/gateway/Dockerfile",
    "services/appview/Dockerfile",
    "services/operations/Dockerfile",
    "services/wire-corpus-edge/Dockerfile",
    "railway/gateway.json",
    "railway/appview.json",
    "railway/operations.json",
    "railway/wire-corpus-edge.json",
  ])("tests migrated Go service coverage for %s", (path) => {
    const result = detect(repositoryWithChange(path), "pull_request");
    expect(result.get("go_packages")).toBe("true");
  });

  it("checks Go runtime parity when a worker library changes", () => {
    const result = detect(repositoryWithChange("packages/go/wireworkercore/cycle.go"), "pull_request");
    expect(result.get("go_packages")).toBe("true");
  });

  it("checks every schema-ready consumer when the local Go module changes", () => {
    const result = detect(repositoryWithChange("packages/go/go.mod"), "pull_request");
    for (const job of ["go_packages", "indexing_worker", "jetstream_ingest", "wire_ingest"]) {
      expect(result.get(job)).toBe("true");
    }
  });

  it("tests portable read-state changes in native and server consumers", () => {
    const result = detect(repositoryWithChange("packages/swift/ReadStateCore/Sources/ReadStateCore/State.swift"), "pull_request");
    for (const job of ["apple", "shared_swift", "go_packages"]) {
      expect(result.get(job)).toBe("true");
    }
  });

  it("tests shared TypeScript read-state changes in the Web job", () => {
    const result = detect(repositoryWithChange("packages/read-state/src/index.ts"), "pull_request");
    expect(result.get("web")).toBe("true");
  });
  it("uses the push before SHA instead of running the full matrix", () => {
    const result = detect(repositoryWithChange("docs/wiki/Testing.md"), "push");
    expect(result.get("docs")).toBe("true");
    expect(result.get("web")).toBe("false");
    expect(result.get("go_packages")).toBe("false");
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

  it("checks every main-schema consumer when its migration manifest changes", () => {
    const result = detect(
      repositoryWithChange("database/migrations/20990101000000_example.sql"),
      "pull_request",
    );
    expect(result.get("go_packages")).toBe("true");
    expect(result.get("shared_swift")).toBe("true");
    expect(result.get("jetstream_ingest")).toBe("true");
    expect(result.get("wire_ingest")).toBe("true");
    expect(result.get("indexing_worker")).toBe("true");
    expect(result.get("wire_corpus_edge")).toBe("true");
    expect(result.get("database_migrator")).toBe("true");
    expect(result.get("spec")).toBe("true");
  });

  it("checks all consumers embedding the shared startup gate", () => {
    const result = detect(
      repositoryWithChange("services/jetstream-ingest/internal/schemaready/gate.go"),
      "pull_request",
    );
    for (const job of ["go_packages", "jetstream_ingest", "wire_ingest", "indexing_worker"]) {
      expect(result.get(job)).toBe("true");
    }
    expect(result.get("wire_corpus_edge")).toBe("false");
  });

  it("checks retained Redis and Swift contracts when their shared package changes", () => {
    const result = detect(
      repositoryWithChange("packages/swift/SocialWireRedis/Sources/SocialWireRedis/RedisCacheClient.swift"),
      "pull_request",
    );
    expect(result.get("redis")).toBe("true");
    expect(result.get("shared_swift")).toBe("true");
    expect(result.get("go_packages")).toBe("true");
    expect(result.get("shared_swift")).toBe("true");
  });

  it("runs deterministic spec coverage when the migration runner changes", () => {
    const result = detect(
      repositoryWithChange("scripts/apply-database-migrations.sh"),
      "pull_request",
    );
    expect(result.get("database_migrator")).toBe("true");
    expect(result.get("spec")).toBe("true");
  });

  it("runs both Bun coverage jobs when their shared inventory gate changes", () => {
    const result = detect(
      repositoryWithChange("scripts/check-bun-coverage-inventory.ts"),
      "pull_request",
    );
    expect(result.get("web")).toBe("true");
    expect(result.get("operations_web")).toBe("true");
    expect(result.get("go_packages")).toBe("false");
  });

  it("runs scope-policy drift checks for Jetstream admission changes", () => {
    const result = detect(
      repositoryWithChange("services/jetstream-ingest/internal/store/postgres.go"),
      "pull_request",
    );
    expect(result.get("jetstream_ingest")).toBe("true");
    expect(result.get("spec")).toBe("true");
  });

  it("runs the replicated worker check for either composed runtime", () => {
    const appView = detect(
      repositoryWithChange("packages/go/appviewworkercore/host.go"),
      "pull_request",
    );
    expect(appView.get("indexing_worker")).toBe("true");

    const wire = detect(
      repositoryWithChange("packages/go/wireworkercore/host.go"),
      "pull_request",
    );
    expect(wire.get("indexing_worker")).toBe("true");
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
  });

  it("runs Python benchmark safety tests when a tool or its tests change", () => {
    for (const path of [
      "scripts/benchmarks/railway_memory_adapters.py",
      "scripts/benchmarks/tests/test_memory_step_acceptance.py",
    ]) {
      const result = detect(repositoryWithChange(path), "pull_request");
      expect(result.get("benchmark_tools")).toBe("true");
      expect(result.get("spec")).toBe("true");
      expect(result.get("go_packages")).toBe("false");
    }
    const unrelated = detect(repositoryWithChange("docs/wiki/Testing.md"), "pull_request");
    expect(unrelated.get("benchmark_tools")).toBe("false");
  });

  for (const path of ["scripts/ci-prepare-postgres.sh", ".github/actions/prepare-postgres/action.yml"]) {
    it(`runs the full matrix when shared PostgreSQL preparation changes: ${path}`, () => {
      const output = detect(repositoryWithChange(path), "pull_request");
      expect(output.size).toBe(15);
      expect([...output.values()].every(value => value === "true")).toBe(true);
    });
  }

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
