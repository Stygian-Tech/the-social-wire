import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const migration = readFileSync(
  join(
    import.meta.dir,
    "../../../supabase/migrations/20260722213000_operations_trust_hardening.sql"
  ),
  "utf8"
);

describe("Operations trust migration", () => {
  it("quarantines malformed lifecycle rows before environment-scoped constraints", () => {
    expect(migration).toContain("SET environment = '__legacy_unscoped__'");
    expect(migration).toContain(
      "verification_status NOT IN ('pending', 'required', 'verified', 'failed')"
    );
    expect(migration).toContain(
      "status NOT IN ('queued', 'running', 'paused', 'completed', 'failed', 'cancelled')"
    );
    expect(migration.indexOf("UPDATE appview_backfill_jobs\nSET environment"))
      .toBeLessThan(migration.indexOf("appview_backfill_jobs_status_check"));
  });

  it("enforces state, version, verification, and strict cursor bounds", () => {
    for (const constraint of [
      "operations_service_state_health_check",
      "appview_ingestion_stream_state_connection_check",
      "operations_commands_action_check",
      "operations_commands_status_check",
      "appview_ingestion_gaps_version_check",
      "appview_backfill_jobs_verification_status_check",
      "appview_backfill_jobs_version_check",
      "operations_alerts_version_check",
    ]) {
      expect(migration).toContain(constraint);
    }
    expect(migration).toContain("start_cursor < end_cursor");
    expect(migration).not.toContain("start_cursor <= end_cursor");
    expect(migration).toContain(
      "verification_status IN ('pending', 'required', 'verified', 'failed')"
    );
  });

  it("keeps quarantined rows out of active uniqueness contracts", () => {
    expect(migration).toContain(
      "WHERE environment <> '__legacy_unscoped__' AND status IN ('queued', 'running')"
    );
    expect(migration).toContain(
      "WHERE environment <> '__legacy_unscoped__' AND status != 'resolved'"
    );
  });

  it("persists lease ownership, canonical idempotency results, and terminal-time retention", () => {
    expect(migration).toContain(
      "ALTER TABLE operations_commands ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ"
    );
    expect(migration).toContain("operations_commands_running_lease_check");
    expect(migration).toContain("request_fingerprint TEXT NOT NULL");
    expect(migration).toContain("result_payload JSONB NOT NULL");
    expect(migration).toContain("COALESCE(completed_at, updated_at, created_at)");
    expect(migration).toContain(
      "SET expires_at = target.terminal_at + INTERVAL '365 days'"
    );
  });
});
