import { afterAll, afterEach, beforeAll, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { join } from "node:path";

const adminURL = process.env.POSTGRES_MIGRATION_TEST_URL;
const psql = process.env.PSQL_BIN ?? "psql";
const migration = join(
  import.meta.dir,
  "../../../database/migrations/20260905040000_remove_redundant_wire_ranked_lookup.sql",
);
const databaseName = `tsw92_migration_guards_${randomUUID().replaceAll("-", "")}`;
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
  return execute(testURL, ["--file", migration]);
}

function fixture(survivingColumns = "generation_id, canonical_key", duplicateUnique = false) {
  sql(`
    CREATE TABLE public.wire_ranked_items (generation_id uuid NOT NULL, canonical_key text NOT NULL);
    CREATE ${duplicateUnique ? "UNIQUE" : ""} INDEX wire_ranked_items_lookup_idx
      ON public.wire_ranked_items (generation_id, canonical_key);
    CREATE UNIQUE INDEX wire_ranked_items_generation_id_canonical_key_key
      ON public.wire_ranked_items (${survivingColumns});
  `);
}

// Never reuse application tables. The supplied connection only provisions a new, isolated
// database, and must explicitly name a local TSW-92 test database to enable destructive fixtures.
describe.skipIf(!adminURL)("redundant Wire index migration PostgreSQL preflight", () => {
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
    if (created) sql("DROP TABLE IF EXISTS public.wire_ranked_items CASCADE");
  });

  afterAll(() => {
    if (!created) return;
    const result = execute(adminURL!, ["--command", `DROP DATABASE ${databaseName} WITH (FORCE)`]);
    if (result.status !== 0) throw new Error(result.stderr);
  });

  it("drops an equivalent duplicate and retains uniqueness", () => {
    fixture();
    const result = applyMigration();
    expect(result.status).toBe(0);
    expect(sql("SELECT to_regclass('public.wire_ranked_items_lookup_idx') IS NULL")).toBe("t");
    expect(sql("SELECT to_regclass('public.wire_ranked_items_generation_id_canonical_key_key') IS NOT NULL")).toBe("t");
    const key = randomUUID();
    sql(`INSERT INTO wire_ranked_items VALUES ('${key}', 'story')`);
    const duplicate = execute(testURL, ["--command", `INSERT INTO wire_ranked_items VALUES ('${key}', 'story')`]);
    expect(duplicate.status).not.toBe(0);
    expect(duplicate.stderr).toContain("duplicate key value violates unique constraint");
  });

  it("rejects a differently ordered surviving unique index without dropping either index", () => {
    fixture("canonical_key, generation_id");
    const result = applyMigration();
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("valid equivalent unique index is absent");
    expect(sql("SELECT to_regclass('public.wire_ranked_items_lookup_idx') IS NOT NULL")).toBe("t");
    expect(sql("SELECT to_regclass('public.wire_ranked_items_generation_id_canonical_key_key') IS NOT NULL")).toBe("t");
  });

  it("can rerun after success without altering the surviving index", () => {
    fixture();
    expect(applyMigration().status).toBe(0);
    const oid = sql("SELECT 'public.wire_ranked_items_generation_id_canonical_key_key'::regclass::oid");
    expect(applyMigration().status).toBe(0);
    expect(sql("SELECT 'public.wire_ranked_items_generation_id_canonical_key_key'::regclass::oid")).toBe(oid);
  });

  it("refuses to drop an otherwise equivalent index that backs a constraint", () => {
    fixture("generation_id, canonical_key", true);
    sql("ALTER TABLE wire_ranked_items ADD CONSTRAINT wire_ranked_items_lookup_idx UNIQUE USING INDEX wire_ranked_items_lookup_idx");
    const result = applyMigration();
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("index backs a constraint");
    expect(sql("SELECT to_regclass('public.wire_ranked_items_lookup_idx') IS NOT NULL")).toBe("t");
  });
});
