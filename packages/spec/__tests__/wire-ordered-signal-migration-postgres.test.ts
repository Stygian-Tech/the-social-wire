import { afterAll, beforeAll, beforeEach, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const adminURL = process.env.POSTGRES_MIGRATION_TEST_URL;
const psql = process.env.PSQL_BIN ?? "psql";
const root = join(import.meta.dir, "../../../database/migrations");
const migration = readFileSync(join(root, "20260927023000_order_wire_signal_mutation.sql"), "utf8");
const database = `tsw92_signal_${randomUUID().replaceAll("-", "")}`;
let url: string;
let created = false;

function execute(target: string, statement: string): string {
  const result = spawnSync(psql, ["-X", "-qAt", "-v", "ON_ERROR_STOP=1", "--dbname", target], {
    input: statement, encoding: "utf8", timeout: 20_000,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout.trim();
}
function sql(statement: string) { return execute(url, statement); }

describe.skipIf(!adminURL)("ordered signal mutation migration PostgreSQL", () => {
  beforeAll(() => {
    const target = new URL(adminURL!);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(target.hostname)
      || !/^\/tsw92_[a-zA-Z0-9_]+$/.test(target.pathname)) {
      throw new Error("POSTGRES_MIGRATION_TEST_URL must target an explicitly disposable local tsw92_* database");
    }
    execute(adminURL!, `CREATE DATABASE ${database}`);
    created = true;
    target.pathname = `/${database}`;
    url = target.toString();
    // A minimal real partitioned source verifies this additive migration in
    // isolation; CI also applies the entire migration history from empty.
    sql(`CREATE UNLOGGED TABLE wire_signal_events (
      event_key text NOT NULL, transport_event_key text, canonical_key text NOT NULL,
      signal_kind text, actor_key_hash text, source_uri text, source_collection text,
      source_action text, occurred_at timestamptz NOT NULL, expires_at timestamptz,
      PRIMARY KEY(event_key, occurred_at), UNIQUE(transport_event_key, occurred_at)
    ) PARTITION BY RANGE (occurred_at);
    ${readFileSync(join(root, "20260907170000_avoid_wire_partition_day_lock.sql"), "utf8")}`);
  });
  beforeEach(() => {
    sql("DROP FUNCTION IF EXISTS public.wire_insert_signal(text,text,text,text,text,text,text,timestamptz,timestamptz); TRUNCATE wire_signal_events");
  });
  afterAll(() => {
    if (created) execute(adminURL!, `DROP DATABASE ${database} WITH (FORCE)`);
  });

  it("installs on an empty source and retains invoker and command-snapshot semantics", () => {
    sql(`BEGIN; ${migration} COMMIT;`);
    expect(sql(`SELECT provolatile = 'v' AND NOT prosecdef
      AND proconfig = ARRAY['search_path=public, pg_temp']
      FROM pg_proc WHERE oid = 'public.wire_insert_signal(text,text,text,text,text,text,text,timestamptz,timestamptz)'::regprocedure`)).toBe("t");
    sql(`SELECT public.wire_insert_signal('event', 'transport', 'first', 'like', 'actor',
      'at://did:example:test/app.bsky.feed.like/first', 'app.bsky.feed.like', '2099-01-02', '2099-01-03')`);
    expect(sql("SELECT count(*) FROM wire_signal_events")).toBe("1");
  });

  it("upgrades existing facts without touching tuples and leaves old callers compatible", () => {
    // Populate through the legacy path before the new function exists.
    sql(`SELECT ensure_wire_signal_event_partition('2099-01-02'::date);
      INSERT INTO wire_signal_events VALUES ('event', 'transport', 'first', 'like', 'actor',
        'existing-source', 'app.bsky.feed.like', 'like', '2099-01-02', '2099-01-03')`);
    const before = sql("SELECT to_jsonb(s)::text || ':' || xmin::text || ':' || ctid::text FROM wire_signal_events s");
    sql(`BEGIN; ${migration} COMMIT;`);
    expect(sql("SELECT to_jsonb(s)::text || ':' || xmin::text || ':' || ctid::text FROM wire_signal_events s")).toBe(before);
    // The legacy four-command shape remains valid after the additive migration.
    sql(`BEGIN;
      SELECT pg_advisory_xact_lock(hashtextextended('legacy-source', 0));
      SELECT ensure_wire_signal_event_partition('2099-01-02'::date);
      DELETE FROM wire_signal_events WHERE source_uri='legacy-source' AND occurred_at<='2099-01-02';
      INSERT INTO wire_signal_events VALUES ('legacy', 'legacy-transport', 'second', 'like', 'actor',
        'legacy-source', 'app.bsky.feed.like', 'like', '2099-01-02', '2099-01-03');
      COMMIT;`);
    expect(sql("SELECT count(*) FROM wire_signal_events")).toBe("2");
  });
});
