import { afterAll, afterEach, beforeAll, describe, expect, it } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const adminURL = process.env.POSTGRES_MIGRATION_TEST_URL;
const psql = process.env.PSQL_BIN ?? "psql";
const migration = join(import.meta.dir, "../../../database/migrations/20260914073000_index_operations_retention.sql");
const databaseName = `tsw92_retention_${randomUUID().replaceAll("-", "")}`;
const targets = [
  ["operations_events", "idx_operations_events_expiry"],
  ["operations_trace_spans", "idx_operations_trace_spans_expiry"],
] as const;
let testURL: string;
let created = false;

function execute(url: string, args: string[], input?: string) {
  const result = spawnSync(psql, ["-X", "--set", "ON_ERROR_STOP=1", "--dbname", url, ...args], {
    input, encoding: "utf8", timeout: 20_000,
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
  const result = execute(testURL, [], readFileSync(migration, "utf8"));
  if (result.status !== 0) throw new Error(result.stderr);
}

function fixture() {
  for (const [table] of targets) {
    sql(`CREATE TABLE ${table} (
      environment text NOT NULL, id bigint NOT NULL, expires_at timestamptz NOT NULL,
      payload text NOT NULL, PRIMARY KEY (environment, id));
      INSERT INTO ${table} VALUES ('prod', 1, '2000-01-01', 'expired'),
        ('prod', 2, '2099-01-01', 'retained'), ('dev', 1, '2000-01-01', 'isolated')`);
  }
}

function indexState(name: string) {
  return JSON.parse(sql(`SELECT json_build_object('oid', i.indexrelid::text,
    'valid', i.indisvalid, 'ready', i.indisready, 'unique', i.indisunique,
    'columns', (SELECT array_agg(a.attname ORDER BY k.ordinality)
      FROM unnest(i.indkey) WITH ORDINALITY k(attnum, ordinality)
      JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum))
    FROM pg_index i WHERE i.indexrelid='public.${name}'::regclass`));
}

function verifyRows() {
  for (const [table] of targets) {
    expect(sql(`SELECT environment || ':' || id || ':' || payload FROM ${table} ORDER BY environment,id`))
      .toBe("dev:1:isolated\nprod:1:expired\nprod:2:retained");
  }
}

type Plan = { "Node Type": string; "Index Name"?: string; "Actual Rows": number;
  "Shared Hit Blocks": number; "Shared Read Blocks": number; Plans?: Plan[] };
function cleanupPlan(table: string): Plan {
  return JSON.parse(sql(`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
    SELECT ctid FROM ${table} WHERE environment='prod' AND expires_at<=statement_timestamp() LIMIT 1000`))[0].Plan;
}
function buffers(plan: Plan) { return plan["Shared Hit Blocks"] + plan["Shared Read Blocks"]; }
function usesIndex(plan: Plan, name: string): boolean {
  return plan["Index Name"] === name || (plan.Plans ?? []).some(child => usesIndex(child, name));
}

describe.skipIf(!adminURL)("Operations retention index migration PostgreSQL", () => {
  beforeAll(() => {
    const base = new URL(adminURL!);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(base.hostname)
      || !/^\/tsw92_[a-zA-Z0-9_]+$/.test(base.pathname)) {
      throw new Error("POSTGRES_MIGRATION_TEST_URL must target an explicitly disposable local tsw92_* database");
    }
    const result = execute(adminURL!, ["--command", `CREATE DATABASE ${databaseName}`]);
    if (result.status !== 0) throw new Error(result.stderr);
    created = true;
    base.pathname = `/${databaseName}`;
    testURL = base.toString();
  });
  afterEach(() => {
    if (created) sql(`DROP TABLE IF EXISTS ${targets.map(([table]) => table).join(", ")} CASCADE`);
  });
  afterAll(() => {
    if (!created) return;
    const result = execute(adminURL!, ["--command", `DROP DATABASE ${databaseName} WITH (FORCE)`]);
    if (result.status !== 0) throw new Error(result.stderr);
  });

  it("creates valid expiry indexes without changing rows or rebuilding valid indexes on retry", () => {
    fixture();
    applyMigration();
    const before = targets.map(([, index]) => indexState(index));
    for (const state of before) {
      expect(state.valid).toBe(true);
      expect(state.ready).toBe(true);
      expect(state.unique).toBe(false);
      expect(state.columns).toEqual(["environment", "expires_at"]);
    }
    applyMigration();
    expect(targets.map(([, index]) => indexState(index))).toEqual(before);
    verifyRows();
  });

  it("rejects an existing valid index with the wrong columns without replacing it", () => {
    fixture();
    sql("CREATE INDEX CONCURRENTLY idx_operations_events_expiry ON operations_events(environment, id)");
    const original = indexState(targets[0][1]);
    expect(original.valid).toBe(true);
    expect(original.columns).toEqual(["environment", "id"]);
    expect(() => applyMigration()).toThrow("valid Operations retention indexes are required");
    expect(indexState(targets[0][1])).toEqual(original);
    verifyRows();
  });

  it("resumes after only the first concurrent index completed", () => {
    fixture();
    sql("CREATE INDEX CONCURRENTLY idx_operations_events_expiry ON operations_events(environment, expires_at)");
    const firstOID = indexState(targets[0][1]).oid;
    applyMigration();
    expect(indexState(targets[0][1]).oid).toBe(firstOID);
    expect(indexState(targets[1][1]).valid).toBe(true);
    verifyRows();
  });

  it("repairs the invalid artifact of an actually interrupted concurrent index build", async () => {
    fixture();
    const blockerURL = new URL(testURL);
    const applicationName = `${databaseName}_writer`;
    blockerURL.searchParams.set("application_name", applicationName);
    const blocker = spawn(psql, ["-X", "--set", "ON_ERROR_STOP=1", "--dbname", blockerURL.toString(),
      "--command", "BEGIN; LOCK TABLE operations_events IN ROW EXCLUSIVE MODE; SELECT pg_sleep(15); ROLLBACK"],
      { stdio: "ignore" });
    const exited = new Promise<void>((resolve, reject) => {
      blocker.once("exit", () => resolve());
      blocker.once("error", reject);
    });
    let invalidOID: string;
    try {
      let locked = false;
      for (let attempt = 0; attempt < 100; attempt++) {
        locked = sql(`SELECT EXISTS (SELECT 1 FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid
          WHERE a.datname=current_database() AND a.application_name='${applicationName}'
            AND l.relation='operations_events'::regclass AND l.mode='RowExclusiveLock' AND l.granted)`) === "t";
        if (locked) break;
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      expect(locked).toBe(true);
      const interrupted = execute(testURL, [], `SET statement_timeout='250ms';
        CREATE INDEX CONCURRENTLY idx_operations_events_expiry ON operations_events(environment, expires_at);`);
      expect(interrupted.status).not.toBe(0);
      expect(interrupted.stderr).toContain("statement timeout");
      const invalid = indexState(targets[0][1]);
      expect(invalid.valid).toBe(false);
      invalidOID = invalid.oid;
    } finally {
      sql(`SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE datname=current_database() AND application_name='${applicationName}'`);
      await exited;
    }
    applyMigration();
    expect(indexState(targets[0][1]).valid).toBe(true);
    expect(indexState(targets[0][1]).oid).not.toBe(invalidOID!);
    expect(indexState(targets[1][1]).valid).toBe(true);
    verifyRows();
  });

  it("bounds sparse and empty cleanup candidate reads on representative retained tables", () => {
    fixture();
    const before = new Map<string, { empty: Plan; sparse: Plan }>();
    for (const [table] of targets) {
      sql(`TRUNCATE ${table}; INSERT INTO ${table}
        SELECT CASE WHEN i%10=0 THEN 'prod' ELSE 'dev' END, i, '2099-01-01'::timestamptz,
          repeat(md5(i::text),16) FROM generate_series(1,30000) i; ANALYZE ${table}`);
      const empty = cleanupPlan(table);
      sql(`INSERT INTO ${table} VALUES ('prod',30001,'2000-01-01','expired-a'),
        ('prod',30002,'2000-01-01','expired-b'); ANALYZE ${table}`);
      before.set(table, { empty, sparse: cleanupPlan(table) });
    }
    applyMigration();
    for (const [table, index] of targets) {
      const baseline = before.get(table)!;
      const sparse = cleanupPlan(table);
      expect(baseline.sparse["Actual Rows"]).toBe(2);
      expect(sparse["Actual Rows"]).toBe(2);
      expect(usesIndex(sparse, index)).toBe(true);
      expect(buffers(sparse)).toBeLessThan(buffers(baseline.sparse) / 4);
      expect(sql(`SELECT id FROM ${table} WHERE environment='prod' AND expires_at<=statement_timestamp() ORDER BY id`))
        .toBe("30001\n30002");
      sql(`DELETE FROM ${table} WHERE environment='prod' AND id IN(30001,30002); ANALYZE ${table}`);
      const empty = cleanupPlan(table);
      expect(baseline.empty["Actual Rows"]).toBe(0);
      expect(empty["Actual Rows"]).toBe(0);
      expect(usesIndex(empty, index)).toBe(true);
      expect(buffers(empty)).toBeLessThan(buffers(baseline.empty) / 4);
    }
  });
});
