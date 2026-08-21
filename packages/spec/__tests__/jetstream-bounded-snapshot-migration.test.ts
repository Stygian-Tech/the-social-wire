import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

const repositoryRoot = join(import.meta.dir, "../../..")
const migration = readFileSync(
  join(
    repositoryRoot,
    "database/migrations/20260821030000_jetstream_bounded_snapshot_completion.sql",
  ),
  "utf8",
)
const postgresStore = readFileSync(
  join(repositoryRoot, "services/jetstream-ingest/internal/store/postgres.go"),
  "utf8",
)

describe("bounded Jetstream snapshot migration", () => {
  it("adds an explicit immutable replay-window identity", () => {
    expect(migration).toContain("ADD COLUMN IF NOT EXISTS replay_before_seq BIGINT")
    expect(migration).toContain("appview_jetstream_checkpoints_replay_bounds_check")
    expect(migration).toContain("replay_after_seq < replay_before_seq")
    expect(migration).toContain("appview_preserve_jetstream_snapshot_identity")
    expect(migration).toContain("NEW.replay_before_seq IS DISTINCT FROM OLD.replay_before_seq")
    expect(migration).toContain("NEW.replay_after_seq IS DISTINCT FROM OLD.replay_after_seq")
  })

  it("makes snapshot completion terminal without inventing a staged event", () => {
    expect(migration).toContain("'snapshot_complete'")
    expect(migration).toContain("appview_jetstream_checkpoints_snapshot_complete_check")
    expect(migration).toContain("replay_sealed_seq = replay_before_seq")
    expect(migration).toContain("last_staged_seq IS NULL")
    expect(migration).toContain("completed bounded snapshot with no matching events")
    expect(migration).toContain("OLD.replay_state = 'snapshot_complete'")
    expect(postgresStore).toContain("'snapshot_complete', $7, $8, $9")
    expect(postgresStore).toContain("cursor_kind, last_staged_seq, last_staged_event_at")
  })

  it("remains provider-neutral", () => {
    expect(migration).not.toContain("service_role")
    expect(migration).not.toContain("authenticated")
    expect(migration).not.toContain("CREATE EXTENSION")
  })
})
