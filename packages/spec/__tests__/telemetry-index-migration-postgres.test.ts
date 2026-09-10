import { afterAll, afterEach, beforeAll, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { readFileSync } from "node:fs";

const adminURL = process.env.POSTGRES_MIGRATION_TEST_URL;
const psql = process.env.PSQL_BIN ?? "psql";
const migration = join(
  import.meta.dir,
  "../../../database/migrations/20260909130000_remove_redundant_telemetry_indexes.sql",
);
const databaseName = `tsw92_telemetry_guards_${randomUUID().replaceAll("-", "")}`;
let testURL: string;
let created = false;

function execute(url: string, arguments_: string[], input?: string) {
  const result = spawnSync(psql, ["-X", "--set", "ON_ERROR_STOP=1", "--dbname", url, ...arguments_], {
    input,
    encoding: "utf8",
    timeout: 15_000,
  });
  if (result.error) throw result.error;
  return result;
}

function sql(statement: string): string {
  const result = execute(testURL, ["--tuples-only", "--no-align"], statement);
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout.trim();
}

function applyMigration() {
  return execute(testURL, [], readFileSync(migration, "utf8"));
}

const tables = ["operations_change_events", "operations_events", "operations_trace_spans"];
const duplicates = ["idx_operations_change_events_replay", "idx_operations_events_environment_id", "idx_operations_traces_environment_id"];

function fixture() {
  for (let i = 0; i < tables.length; i++) {
    const key = i === 0 ? "cursor bigint" : "id text";
    const column = i === 0 ? "cursor" : "id";
    sql(`CREATE TABLE ${tables[i]} (environment text NOT NULL, ${key} NOT NULL, payload text, PRIMARY KEY (environment, ${column}));
      CREATE ${i === 0 ? "" : "UNIQUE"} INDEX ${duplicates[i]} ON ${tables[i]} (environment, ${column});
      INSERT INTO ${tables[i]} VALUES ('prod', ${i === 0 ? "1" : "'same-id'"}, 'retained'), ('dev', ${i === 0 ? "1" : "'same-id'"}, 'isolated');`);
  }
}

function present(name: string) {
  return sql(`SELECT to_regclass('public.${name}') IS NOT NULL`) === "t";
}

describe.skipIf(!adminURL)("telemetry index migration PostgreSQL preflight", () => {
  beforeAll(() => {
    const base = new URL(adminURL!);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(base.hostname)
      || !/^\/tsw92_[a-zA-Z0-9_]+$/.test(base.pathname)) {
      throw new Error("POSTGRES_MIGRATION_TEST_URL must target an explicitly disposable local tsw92_* database");
    }
    const create = execute(adminURL!, ["--command", `CREATE DATABASE ${databaseName}`]);
    if (create.status !== 0) throw new Error(create.stderr);
    created = true;
    base.pathname = `/${databaseName}`;
    testURL = base.toString();
  });
  afterEach(() => {
    if (created) sql(`DROP TABLE IF EXISTS telemetry_child, ${tables.join(", ")} CASCADE`);
  });
  afterAll(() => {
    if (!created) return;
    const result = execute(adminURL!, ["--command", `DROP DATABASE ${databaseName} WITH (FORCE)`]);
    if (result.status !== 0) throw new Error(result.stderr);
  });

  it("preserves rows, environment isolation, primary keys and replay order on success and retry", () => {
    fixture();
    expect(applyMigration().status).toBe(0);
    const oids = tables.map(table => sql(`SELECT '${table}_pkey'::regclass::oid`));
    expect(applyMigration().status).toBe(0);
    tables.forEach((table, i) => {
      expect(present(duplicates[i]!)).toBe(false);
      expect(sql(`SELECT '${table}_pkey'::regclass::oid`)).toBe(oids[i]!);
      expect(sql(`SELECT payload FROM ${table} ORDER BY environment`)).toBe("isolated\nretained");
      const conflict = execute(testURL, ["--command", `INSERT INTO ${table} SELECT * FROM ${table} WHERE environment='prod'`]);
      expect(conflict.status).not.toBe(0);
      expect(conflict.stderr).toContain("duplicate key");
    });
    sql("INSERT INTO operations_change_events VALUES ('prod', 3, 'three'), ('prod', 2, 'two')");
    expect(sql("SELECT cursor FROM operations_change_events WHERE environment='prod' AND cursor>1 ORDER BY cursor LIMIT 2")).toBe("2\n3");
  });

  it("preflights every index before removing any when a retained key differs", () => {
    fixture();
    sql("ALTER TABLE operations_trace_spans DROP CONSTRAINT operations_trace_spans_pkey; ALTER TABLE operations_trace_spans ADD PRIMARY KEY (id, environment)");
    const result = applyMigration();
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("valid equivalent primary-key index is absent");
    for (const index of duplicates) expect(present(index)).toBe(true);
  });

  it("rejects a duplicate with included columns", () => {
    fixture();
    sql("DROP INDEX idx_operations_traces_environment_id; CREATE UNIQUE INDEX idx_operations_traces_environment_id ON operations_trace_spans(environment,id) INCLUDE(payload)");
    expect(applyMigration().status).not.toBe(0);
    for (const index of duplicates) expect(present(index)).toBe(true);
  });

  it("preserves a duplicate used by a foreign key", () => {
    fixture();
    sql(`ALTER TABLE operations_events DROP CONSTRAINT operations_events_pkey;
      CREATE TABLE telemetry_child (environment text, id text, FOREIGN KEY(environment,id) REFERENCES operations_events(environment,id));
      ALTER TABLE operations_events ADD PRIMARY KEY (environment,id)`);
    const result = applyMigration();
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("constraint, dependency, or identity role");
    for (const index of duplicates) expect(present(index)).toBe(true);
  });

  it("resumes after only the first concurrent drop completed", () => {
    fixture();
    sql("DROP INDEX idx_operations_change_events_replay");
    expect(applyMigration().status).toBe(0);
    for (const index of duplicates) expect(present(index)).toBe(false);
  });
});
