import { afterAll, beforeAll, beforeEach, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const adminURL = process.env.POSTGRES_MIGRATION_TEST_URL;
const psql = process.env.PSQL_BIN ?? "psql";
const migration = readFileSync(join(import.meta.dir,
  "../../../database/migrations/20260926190000_bound_operations_change_event_retention.sql"), "utf8");
const original = readFileSync(join(import.meta.dir,
  "../../../database/migrations/20260722213000_operations_trust_hardening.sql"), "utf8")
  .split("CREATE OR REPLACE FUNCTION operations_cleanup_expired(")[1].split("\nDO $$")[0];
const originalFunction = `CREATE OR REPLACE FUNCTION operations_cleanup_expired(${original}`;
const databaseName = `tsw92_change_retention_${randomUUID().replaceAll("-", "")}`;
const tables = [...original.matchAll(/SELECT ctid(?:, cursor)? FROM (\w+)/g)].map(match => match[1]);
let testURL: string;
let created = false;

function execute(url: string, statement: string): string {
  const result = spawnSync(psql, ["-X", "-q", "-A", "-t", "--set", "ON_ERROR_STOP=1", "--dbname", url], {
    input: statement, encoding: "utf8", timeout: 30_000,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout.trim();
}
function sql(statement: string) { return execute(testURL, statement); }
function apply() { sql(`BEGIN; ${migration} COMMIT;`); }
function seed() {
  sql(`TRUNCATE ${tables.join(",")}, operations_change_event_watermarks;
    INSERT INTO operations_change_event_watermarks VALUES ('dev',1,'2000-01-01'),('prod',1,'2000-01-01');
    INSERT INTO operations_change_events(environment,cursor,expires_at) VALUES
      ('dev',1,'2099-01-01'),('dev',2,'2000-02-01'),('dev',3,'2000-01-01'),
      ('dev',4,'2000-03-01'),('dev',5,'2099-01-01'),('prod',2,'2000-01-01');
    INSERT INTO operations_commands(environment,status,expires_at) VALUES
      ('dev','running','2000-01-01'),('dev','completed','2000-01-01');
    INSERT INTO operations_alerts(environment,status,expires_at) VALUES
      ('dev','open','2000-01-01'),('dev','resolved','2000-01-01');
    INSERT INTO appview_backfill_jobs(environment,status,expires_at) VALUES
      ('dev','running','2000-01-01'),('dev','cancelled','2000-01-01');
    INSERT INTO appview_ingestion_gaps(environment,status,expires_at) VALUES
      ('dev','open','2000-01-01'),('dev','ignored','2000-01-01');`);
}
function snapshot() {
  return sql(`SELECT json_build_object(
    'events',(SELECT json_agg(row(environment,cursor) ORDER BY environment,cursor) FROM operations_change_events),
    'watermarks',(SELECT json_agg(row(environment,earliest_available_cursor,updated_at) ORDER BY environment) FROM operations_change_event_watermarks),
    'commands',(SELECT json_agg(status ORDER BY status) FROM operations_commands),
    'alerts',(SELECT json_agg(status ORDER BY status) FROM operations_alerts),
    'backfills',(SELECT json_agg(status ORDER BY status) FROM appview_backfill_jobs),
    'gaps',(SELECT json_agg(status ORDER BY status) FROM appview_ingestion_gaps))`);
}

it("changes only the change-event selection while preserving other retention and watermark clauses", () => {
  // Compare outside the targeted block without depending on a function's SQL formatting.
  const cut = (body: string) => {
    const start = body.indexOf("  WITH doomed AS (\n    SELECT ctid, cursor FROM operations_change_events");
    const replacementStart = body.indexOf("  -- Isolate the expiry range");
    const from = start < 0 ? replacementStart : start;
    const end = body.indexOf("\n  affected := affected + row_count;", from);
    return body.slice(0, from) + body.slice(end);
  };
  const candidateFunction = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION"))
    .split("\nREVOKE ALL")[0].trim();
  expect(cut(candidateFunction)).toBe(cut(originalFunction.trim()));
  expect(migration).toContain("expired AS MATERIALIZED");
  expect(migration).toContain("SELECT cursor FROM expired ORDER BY cursor LIMIT bounded_batch");
});

describe.skipIf(!adminURL)("Operations change-event retention migration PostgreSQL", () => {
  beforeAll(() => {
    const base = new URL(adminURL!);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(base.hostname)
      || !/^\/tsw92_[a-zA-Z0-9_]+$/.test(base.pathname)) {
      throw new Error("POSTGRES_MIGRATION_TEST_URL must target a disposable local tsw92_* database");
    }
    execute(adminURL!, `CREATE DATABASE ${databaseName}`);
    created = true;
    base.pathname = `/${databaseName}`;
    testURL = base.toString();
    for (const table of tables) {
      sql(`CREATE TABLE ${table}(environment text NOT NULL, cursor bigint,
        expires_at timestamptz, heartbeat_at timestamptz, status text, payload text)`);
    }
    sql(`ALTER TABLE operations_change_events ADD PRIMARY KEY(environment,cursor);
      CREATE INDEX idx_operations_change_events_expiry ON operations_change_events(environment,expires_at,cursor);
      CREATE TABLE operations_change_event_watermarks(environment text PRIMARY KEY,
        earliest_available_cursor bigint NOT NULL, updated_at timestamptz NOT NULL)`);
  });
  beforeEach(() => { seed(); });
  afterAll(() => { if (created) execute(adminURL!, `DROP DATABASE ${databaseName} WITH (FORCE)`); });

  it("installs fresh and upgrades idempotently without changing rows or function grants", () => {
    sql("DROP FUNCTION IF EXISTS operations_cleanup_expired(text,timestamptz,integer)");
    const before = snapshot();
    apply();
    const oid = sql("SELECT 'operations_cleanup_expired(text,timestamptz,integer)'::regprocedure::oid");
    apply();
    expect(snapshot()).toBe(before);
    expect(sql("SELECT 'operations_cleanup_expired(text,timestamptz,integer)'::regprocedure::oid")).toBe(oid);
    expect(sql("SELECT EXISTS(SELECT 1 FROM pg_proc p,LATERAL aclexplode(p.proacl) acl WHERE p.oid='operations_cleanup_expired(text,timestamptz,integer)'::regprocedure AND acl.grantee=0 AND acl.privilege_type='EXECUTE')")).toBe("f");
    sql(originalFunction);
    apply();
    expect(snapshot()).toBe(before);
  });

  it("matches cursor-ordered batches, out-of-order expiry, environment isolation and protected history", () => {
    sql(originalFunction);
    const deleted = sql("SELECT operations_cleanup_expired('dev','2026-09-26',2)");
    const expected = snapshot();
    seed();
    apply();
    expect(sql("SELECT operations_cleanup_expired('dev','2026-09-26',2)")).toBe(deleted);
    expect(snapshot()).toBe(expected);
    expect(sql("SELECT cursor FROM operations_change_events WHERE environment='dev' ORDER BY cursor")).toBe("1\n4\n5");
    expect(sql("SELECT earliest_available_cursor FROM operations_change_event_watermarks WHERE environment='dev'")).toBe("4");
    expect(sql("SELECT status FROM operations_commands")).toBe("running");
    expect(sql("SELECT status FROM operations_alerts")).toBe("open");
    expect(sql("SELECT status FROM appview_backfill_jobs")).toBe("running");
    expect(sql("SELECT status FROM appview_ingestion_gaps")).toBe("open");
  });

  it("rolls back event deletion and its watermark together and leaves empty cleanup unchanged", () => {
    apply();
    const before = snapshot();
    sql("BEGIN; SELECT operations_cleanup_expired('dev','2026-09-26',2); ROLLBACK;");
    expect(snapshot()).toBe(before);
    sql("SELECT operations_cleanup_expired('dev','2026-09-26',1000)");
    const drained = snapshot();
    expect(sql("SELECT operations_cleanup_expired('dev','2026-09-26',1000)")).toBe("0");
    expect(snapshot()).toBe(drained);
  });

  it("uses the covering expiry index for sparse and empty history without scanning retained payloads", () => {
    apply();
    sql(`TRUNCATE operations_change_events;
      INSERT INTO operations_change_events(environment,cursor,expires_at,payload)
      SELECT 'dev',i,CASE WHEN i<=3000 THEN '2000-01-01'::timestamptz ELSE '2099-01-01'::timestamptz END,
        repeat(md5(i::text),32) FROM generate_series(1,30000) i;
      INSERT INTO operations_change_events(environment,cursor,expires_at) VALUES ('dev',30001,'2000-01-01');
      ALTER TABLE operations_change_events SET (autovacuum_enabled=false);
      ANALYZE operations_change_events;
      UPDATE operations_change_events SET expires_at='2099-01-01' WHERE cursor<=3000;
      VACUUM operations_change_events`);
    const originalSelect = "SELECT ctid,cursor FROM operations_change_events WHERE environment='dev' AND expires_at<='2026-09-26' ORDER BY cursor LIMIT 1000";
    const newSelect = "WITH expired AS MATERIALIZED (SELECT cursor FROM operations_change_events WHERE environment='dev' AND expires_at<='2026-09-26') SELECT cursor FROM expired ORDER BY cursor LIMIT 1000";
    for (const expectedRows of [1, 0]) {
      const plan = (query: string) => JSON.parse(sql(`EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) ${query}`))[0].Plan;
      const old = plan(originalSelect);
      const next = plan(newSelect);
      expect(next["Actual Rows"]).toBe(expectedRows);
      expect(JSON.stringify(next)).toContain("idx_operations_change_events_expiry");
      const buffers = (value: typeof next) => value["Shared Hit Blocks"] + value["Shared Read Blocks"];
      expect(buffers(next)).toBeLessThan(buffers(old) / 4);
      sql("DELETE FROM operations_change_events WHERE cursor=30001; VACUUM operations_change_events");
    }
  });
});
