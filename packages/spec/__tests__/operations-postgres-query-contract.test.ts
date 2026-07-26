import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const postgresStore = readFileSync(
  join(
    repositoryRoot,
    "packages/swift/OperationsCore/Sources/OperationsCore/PostgresOperationsStore.swift"
  ),
  "utf8"
);

describe("Operations Postgres query contracts", () => {
  it("casts nullable pagination and metric filter parameters", () => {
    expect(postgresStore).not.toContain("\\(beforeDate) IS NULL");
    expect(postgresStore).not.toContain("\\(metricName) IS NULL");
    expect(postgresStore).not.toContain("\\(collection) IS NULL");

    expect(postgresStore.match(/\\\(beforeDate\)::timestamptz IS NULL/g)).toHaveLength(6);
    expect(postgresStore).toContain("\\(beforeId)::text");
    expect(postgresStore).toContain("\\(metricName)::text IS NULL");
    expect(postgresStore).toContain("\\(collection)::text IS NULL");
  });

  it("matches the retention function integer signature", () => {
    expect(postgresStore).toContain(
      "\\(max(1, min(batchSize, 10_000)))::integer"
    );
  });
});
