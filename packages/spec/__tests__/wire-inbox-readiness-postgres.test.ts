import { afterAll, beforeAll, beforeEach, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const adminURL = process.env.POSTGRES_MIGRATION_TEST_URL;
const psql = process.env.PSQL_BIN ?? "psql";
const script = readFileSync(join(import.meta.dir, "../../../scripts/operations/wire-inbox-readiness.sql"), "utf8");
const query = script.split("-- BEGIN DIAGNOSTIC QUERY\n")[1]!.split("-- END DIAGNOSTIC QUERY")[0]!;
const databaseName = `tsw122_readiness_${randomUUID().replaceAll("-", "")}`;
let testURL: string;
let created = false;

function execute(url: string, statement: string): string {
  const result = spawnSync(psql, ["-X", "-qAt", "-v", "ON_ERROR_STOP=1", "--dbname", url], {
    input: statement, encoding: "utf8", timeout: 15_000,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout.trim();
}
function sql(statement: string): string { return execute(testURL, statement); }
function snapshot() { return JSON.parse(sql(script)); }
function insertRows(rows: string) {
  sql(`INSERT INTO wire_ingestion_inbox
    (environment, source_generation, repo_did, seq, status, staged_at, next_attempt_at, lease_expires_at)
    VALUES ${rows}`);
}

// Every fixture owns an isolated local database; no hosted connection is accepted.
describe.skipIf(!adminURL)("Wire inbox bounded readiness PostgreSQL diagnostic", () => {
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
    sql(`CREATE TABLE wire_ingestion_inbox (
      environment text NOT NULL, source_generation text NOT NULL, repo_did text NOT NULL,
      seq bigint NOT NULL, status text NOT NULL, staged_at timestamptz NOT NULL,
      next_attempt_at timestamptz, lease_expires_at timestamptz,
      PRIMARY KEY(environment, source_generation, seq));
      CREATE INDEX wire_ingestion_inbox_pending_retry_ready_idx
        ON wire_ingestion_inbox(next_attempt_at, seq) WHERE status IN ('pending', 'retry');
      CREATE INDEX wire_ingestion_inbox_expired_lease_idx
        ON wire_ingestion_inbox(lease_expires_at, seq) WHERE status = 'leased';
      CREATE INDEX wire_ingestion_inbox_repo_fifo_idx
        ON wire_ingestion_inbox(environment, source_generation, repo_did, seq)
        WHERE status IN ('pending', 'leased', 'retry')`);
  });
  beforeEach(() => sql("TRUNCATE wire_ingestion_inbox"));
  afterAll(() => { if (created) execute(adminURL!, `DROP DATABASE ${databaseName} WITH (FORCE)`); });

  it("reports no due work and NULL ages without mutating session or durable data", () => {
    const result = snapshot();
    expect(result.duePresent).toBe(false);
    expect(result.sampledDueRows).toBe(0);
    expect(result.sampledFIFOEligibleHeads).toBe(0);
    expect(result.sampledOldestDueAgeLowerBoundSeconds).toBeNull();
    expect(result.sampledOldestFIFOEligibleStagedAgeLowerBoundSeconds).toBeNull();
    expect(Number.isNaN(Date.parse(result.observedAt))).toBe(false);
    expect(script).toContain("BEGIN READ ONLY");
    expect(script).toContain("SET LOCAL statement_timeout = '3s'");
    expect(script).toContain("ROLLBACK;");
  });

  it("separates due followers from FIFO heads and preserves source/environment isolation", () => {
    insertRows(`
      ('prod','g','future-retry',1,'retry',now()-interval '10m',now()+interval '1h',NULL),
      ('prod','g','future-retry',2,'pending',now()-interval '9m',now()-interval '9m',NULL),
      ('prod','g','live-lease',3,'leased',now()-interval '8m',NULL,now()+interval '1h'),
      ('prod','g','live-lease',4,'retry',now()-interval '7m',now()-interval '7m',NULL),
      ('prod','g','expired',5,'leased',now()-interval '6m',NULL,now()-interval '5m'),
      ('prod','g','terminal',6,'dead_letter',now()-interval '5m',now()-interval '5m',NULL),
      ('prod','g','terminal',7,'pending',now()-interval '4m',now()-interval '4m',NULL),
      ('prod','other','isolated-generation',8,'pending',now(),now()+interval '1h',NULL),
      ('prod','g','isolated-generation',9,'pending',now()-interval '3m',now()-interval '3m',NULL),
      ('dev','g','isolated-environment',10,'pending',now(),now()+interval '1h',NULL),
      ('prod','g','isolated-environment',11,'pending',now()-interval '2m',now()-interval '2m',NULL)`);
    const before = sql("SELECT md5(string_agg(row_to_json(t)::text, ',' ORDER BY environment,source_generation,seq)) FROM wire_ingestion_inbox t");
    const result = snapshot();
    expect(result.duePresent).toBe(true);
    expect(result.sampledDueRows).toBe(6);
    expect(result.sampledFIFOEligibleHeads).toBe(4);
    expect(result.sampledFIFOBlockedRows).toBe(2);
    expect(result.pendingRetrySampleTruncated).toBe(false);
    expect(result.expiredLeaseSampleTruncated).toBe(false);
    expect(result.sampledOldestStagedAgeLowerBoundSeconds).toBeGreaterThanOrEqual(540);
    expect(result.sampledOldestFIFOEligibleStagedAgeLowerBoundSeconds).toBeGreaterThanOrEqual(360);
    expect(JSON.stringify(result)).not.toContain("future-retry");
    expect(sql("SELECT md5(string_agg(row_to_json(t)::text, ',' ORDER BY environment,source_generation,seq)) FROM wire_ingestion_inbox t")).toBe(before);
  });

  it("does not claim absence of eligible heads when a blocked sample is truncated", () => {
    insertRows("('prod','g','dense',0,'retry',now()-interval '1h',now()+interval '1h',NULL)");
    sql(`INSERT INTO wire_ingestion_inbox SELECT 'prod','g','dense',seq,'pending',
      now()-interval '20m', now()-interval '10m', NULL FROM generate_series(1,100) seq`);
    insertRows("('prod','g','later-eligible',101,'pending',now()-interval '5m',now()-interval '5m',NULL)");
    const result = snapshot();
    expect(result.sampledDueRows).toBe(64);
    expect(result.sampledFIFOEligibleHeads).toBe(0);
    expect(result.sampledFIFOBlockedRows).toBe(64);
    expect(result.pendingRetrySampleTruncated).toBe(true);
    expect(result.sampledOldestFIFOEligibleStagedAgeLowerBoundSeconds).toBeNull();
    expect(result).not.toHaveProperty("fifoEligiblePresent");
    expect(result).not.toHaveProperty("actionablePresent");
  });

  it("does not mark an exact 64-row branch sample as truncated", () => {
    sql(`INSERT INTO wire_ingestion_inbox SELECT 'prod','g','due-'||seq,seq,'pending',
      now()-interval '1m',now()-interval '1m',NULL FROM generate_series(1,64) seq;
      INSERT INTO wire_ingestion_inbox SELECT 'prod','g','lease-'||seq,seq,'leased',
      now()-interval '1m',NULL,now()-interval '1m' FROM generate_series(65,128) seq`);
    const result = snapshot();
    expect(result.sampledDueRows).toBe(128);
    expect(result.sampledFIFOEligibleHeads).toBe(128);
    expect(result.pendingRetrySampleTruncated).toBe(false);
    expect(result.expiredLeaseSampleTruncated).toBe(false);
  });

  it("bounds both branches and uses the existing due/FIFO indexes under sparse backlog", () => {
    sql(`INSERT INTO wire_ingestion_inbox SELECT 'prod','g','future-'||seq,seq,'pending',
      now(),now()+interval '1h',NULL FROM generate_series(1,20000) seq;
      INSERT INTO wire_ingestion_inbox SELECT 'prod','g','due-'||seq,seq,'pending',
      now()-interval '1m',now()-interval '1m',NULL FROM generate_series(20001,20100) seq;
      INSERT INTO wire_ingestion_inbox SELECT 'prod','g','lease-'||seq,seq,'leased',
      now()-interval '1m',NULL,now()-interval '1m' FROM generate_series(20101,20200) seq;
      ANALYZE wire_ingestion_inbox`);
    const result = snapshot();
    expect(result.sampledDueRows).toBe(128);
    expect(result.sampledFIFOEligibleHeads).toBe(128);
    expect(result.pendingRetrySampleTruncated).toBe(true);
    expect(result.expiredLeaseSampleTruncated).toBe(true);
    const plan = sql(`BEGIN READ ONLY; SET LOCAL statement_timeout='3s'; EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${query} ROLLBACK;`);
    for (const index of ["pending_retry_ready_idx", "expired_lease_idx", "repo_fifo_idx"]) {
      expect(plan).toContain(`wire_ingestion_inbox_${index}`);
    }
    expect(plan).not.toContain('"Node Type": "Seq Scan"');
  });
});
