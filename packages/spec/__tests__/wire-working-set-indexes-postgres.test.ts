import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const adminURL = process.env.POSTGRES_MIGRATION_TEST_URL;
const database = `tsw92_workset_${randomUUID().replaceAll("-", "")}`;
const root = join(import.meta.dir, "../../../database/migrations");
const migrations = [
  ["20261007010100_index_wire_metadata_qualification_backfill.sql", "wire_metadata_qualification_pending_idx", "wire_link_metadata_cache"],
  ["20261007010200_index_wire_representative_uri.sql", "wire_items_representative_uri_idx", "wire_items"],
  ["20261007010300_index_wire_qualified_metadata.sql", "wire_metadata_qualified_key_idx", "wire_link_metadata_cache"],
] as const;
let url: string;
let created = false;
function execute(target: string, statement: string, succeeds = true): string {
  const result = spawnSync(process.env.PSQL_BIN ?? "psql", ["-X", "-qAt", "-v", "ON_ERROR_STOP=1", "--dbname", target], {
    input: statement, encoding: "utf8", timeout: 20_000,
  });
  if (result.error) throw result.error;
  if (succeeds && result.status !== 0) throw new Error(result.stderr);
  if (!succeeds) expect(result.status).not.toBe(0);
  return result.stdout.trim();
}
function sql(statement: string, succeeds = true) { return execute(url, statement, succeeds); }

describe.skipIf(!adminURL)("Wire working-set concurrent index migrations", () => {
  beforeAll(() => {
    const target = new URL(adminURL!);
    if (!["127.0.0.1", "localhost", "[::1]"].includes(target.hostname)
      || !/^\/tsw92_[a-zA-Z0-9_]+$/.test(target.pathname)) {
      throw new Error("POSTGRES_MIGRATION_TEST_URL requires an explicitly disposable local tsw92_* database");
    }
    execute(adminURL!, `CREATE DATABASE ${database}`); created = true;
    target.pathname = `/${database}`; url = target.toString();
    sql(`CREATE TABLE wire_items(canonical_key text, representative_uri text);
      CREATE TABLE wire_link_metadata_cache(canonical_key text, open_graph_qualified boolean, stale_until timestamptz);
      INSERT INTO wire_items VALUES('first','same'),('second','same');
      INSERT INTO wire_link_metadata_cache VALUES('same',true,now()),('same',true,now()),('same',NULL,NULL),('same',NULL,NULL);`);
  });
  afterAll(() => { if (created) execute(adminURL!, `DROP DATABASE ${database} WITH (FORCE)`); });

  it("installs on populated sources and is idempotent without rewriting rows", () => {
    const before = sql("SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('ctid',ctid::text,'xmin',xmin::text)) FROM wire_link_metadata_cache t");
    for (const [file] of migrations) { const migration = readFileSync(join(root, file), "utf8"); sql(migration); sql(migration); }
    expect(sql("SELECT jsonb_agg(to_jsonb(t)||jsonb_build_object('ctid',ctid::text,'xmin',xmin::text)) FROM wire_link_metadata_cache t")).toBe(before);
    expect(sql(`SELECT count(*) FROM pg_index WHERE indexrelid IN (${migrations.map(([, index]) => `'${index}'::regclass`).join(",")}) AND indisvalid AND indisready`)).toBe("3");
  });

  it("repairs actual failed concurrent-build artifacts before retrying", () => {
    for (const [file, index, table] of migrations) {
      sql(`DROP INDEX ${index}`);
      // A duplicate-key build fails after registering a real invalid index shell.
      sql(`CREATE UNIQUE INDEX CONCURRENTLY ${index} ON ${table} ((true))`, false);
      expect(sql(`SELECT indisvalid FROM pg_index WHERE indexrelid='${index}'::regclass`)).toBe("f");
      sql(readFileSync(join(root, file), "utf8"));
      expect(sql(`SELECT indisvalid AND indisready AND NOT indisunique FROM pg_index WHERE indexrelid='${index}'::regclass`)).toBe("t");
    }
  });

  it("fails closed on a colliding non-index object without removing it", () => {
    const [file, index] = migrations[0];
    sql(`DROP INDEX ${index}; CREATE TABLE ${index}(marker text); INSERT INTO ${index} VALUES('preserved')`);
    sql(readFileSync(join(root, file), "utf8"), false);
    expect(sql(`SELECT marker FROM ${index}`)).toBe("preserved");
  });
});
