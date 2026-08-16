import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

const repositoryRoot = join(import.meta.dir, "../../..")
const migration = readFileSync(
  join(repositoryRoot, "database/migrations/20260815190000_jetstream_v2_durable_ingestion.sql"),
  "utf8",
)
const legacyTool = readFileSync(
  join(repositoryRoot, "scripts/operations/legacy-gap-incidents.sql"),
  "utf8",
)
const postgresOperationsStore = readFileSync(
  join(repositoryRoot, "packages/swift/OperationsCore/Sources/OperationsCore/PostgresOperationsStore+DurableIngestion.swift"),
  "utf8",
)
const sqliteOperationsStore = readFileSync(
  join(repositoryRoot, "packages/swift/OperationsCore/Sources/OperationsCore/SQLiteOperationsStore+DurableIngestion.swift"),
  "utf8",
)

describe("Jetstream V2 durable ingestion migration", () => {
  it("keeps Supabase role grants optional on provider-neutral Postgres", () => {
    expect(migration).toContain("SELECT 1 FROM pg_roles WHERE rolname = 'anon'")
    expect(migration).toContain("SELECT 1 FROM pg_roles WHERE rolname = 'service_role'")
    expect(migration).not.toContain("FROM anon, authenticated")
  })

  it("binds checkpoints to an exact source identity and stages events idempotently", () => {
    expect(migration).toContain("PRIMARY KEY (environment, source_generation)")
    expect(migration).toContain("source_host TEXT NOT NULL")
    expect(migration).toContain("stream_nsid TEXT NOT NULL")
    expect(migration).toContain("filter_fingerprint TEXT NOT NULL")
    expect(migration).toContain("cursor_kind IN ('jetstream_v2_seq')")
    expect(migration).toContain("PRIMARY KEY (environment, source_generation, seq)")
    expect(migration).toContain("next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW()")
  })

  it("keeps replay usage and leadership durable across process restarts", () => {
    expect(migration).toContain("CREATE TABLE IF NOT EXISTS appview_ingestion_replay_usage")
    expect(migration).toContain("date_trunc('minute', bucket_started_at)")
    expect(migration).toContain("CREATE TABLE IF NOT EXISTS appview_ingestion_leases")
    expect(migration).toContain("fencing_token BIGINT NOT NULL")
    expect(migration).toContain("released_at TIMESTAMPTZ")
  })

  it("counts only dead letters that have not been reconciled", () => {
    expect(postgresOperationsStore).toContain("status = 'dead_letter' AND reconciled_at IS NULL")
    expect(sqliteOperationsStore).toContain("status = 'dead_letter' AND reconciled_at IS NULL")
  })

  it("retains and links legacy gap evidence without converting timestamp cursors to V2 sequences", () => {
    expect(migration).toContain("ON DELETE RESTRICT")
    expect(migration).toContain("CREATE TRIGGER appview_preserve_linked_ingestion_gap_trigger")
    expect(legacyTool).toContain("'jetstream_v1_time_us'")
    expect(legacyTool).toContain("cursorSemantics', 'timestamp_microseconds'")
    expect(legacyTool).toContain("'unbounded-' || TO_CHAR")
    expect(legacyTool).toContain("cluster.cluster_key = member.cluster_key")
    expect(legacyTool).not.toContain("DELETE FROM appview_ingestion_gaps")
    expect(legacyTool).not.toContain("jetstream_v2_seq")
  })
})
