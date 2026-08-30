import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const migration = readFileSync(
  join(
    repositoryRoot,
    "database/migrations/20260829210000_add_wire_actor_signal_lookup_index.sql",
  ),
  "utf8",
);
const wireSchemaMigration = readFileSync(
  join(
    repositoryRoot,
    "database/migrations/20260820120000_add_wire_discovery_feed.sql",
  ),
  "utf8",
);

const normalizedMigration = migration.replace(/\s+/g, " ");

describe("Your Circle signal lookup migration", () => {
  it("adds the exact actor-time covering index for seven-day candidate scans", () => {
    expect(normalizedMigration).toContain(
      "ON ONLY public.wire_signal_events " +
        "(actor_key_hash, occurred_at DESC, canonical_key) " +
        "INCLUDE (source_uri, signal_kind, source_collection, source_action)",
    );
    expect(migration).toContain("wire_signal_events_actor_time_idx");
    expect(migration).toContain("actor_key_hash = ANY($1)");
    expect(migration).toContain("occurred_at >= $2");
    for (const selectedColumn of [
      "canonical_key",
      "signal_kind",
      "actor_key_hash",
      "source_uri",
      "occurred_at",
      "source_collection",
      "source_action",
    ]) {
      expect(migration).toContain(selectedColumn);
    }
  });

  it("backfills non-null provenance while preserving rolling-writer compatibility", () => {
    expect(normalizedMigration).toContain(
      "ADD COLUMN IF NOT EXISTS source_collection TEXT DEFAULT 'unknown'",
    );
    expect(normalizedMigration).toContain(
      "ADD COLUMN IF NOT EXISTS source_action TEXT DEFAULT 'unknown'",
    );
    expect(normalizedMigration).toContain(
      "WHEN source_collection <> 'unknown' THEN source_collection " +
        "WHEN source_uri ~ '^at://[^/]+/[^/]+' THEN split_part(source_uri, '/', 4)",
    );
    expect(normalizedMigration).toContain(
      "WHEN source_action = 'unknown' THEN signal_kind ELSE source_action",
    );
    expect(normalizedMigration).toContain(
      "ALTER COLUMN source_collection SET NOT NULL",
    );
    expect(normalizedMigration).toContain("ALTER COLUMN source_action SET NOT NULL");
  });

  it("keeps an external-free v10 rollup beside the inclusive v11 inputs", () => {
    for (const column of [
      "baseline_last_signal_at",
      "baseline_distinct_actors_1h",
      "baseline_distinct_actors_24h",
      "baseline_distinct_actors_7d",
      "baseline_signals_1h",
      "baseline_signals_24h",
      "baseline_signals_7d",
      "baseline_recommendations_24h",
      "baseline_shares_1h",
      "baseline_shares_24h",
      "baseline_distinct_likers_24h",
      "baseline_likes_1h",
      "baseline_likes_24h",
    ]) {
      expect(migration).toContain(`ADD COLUMN IF NOT EXISTS ${column}`);
    }
  });

  it("builds partition leaf indexes online and attaches them for future inheritance", () => {
    expect(migration).toContain("-- socialwire:transaction=off");
    expect(migration).toContain("CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON %s");
    expect(migration).toContain("DROP INDEX CONCURRENTLY IF EXISTS %s");
    expect(migration).toContain(
      "ALTER INDEX public.wire_signal_events_actor_time_idx ATTACH PARTITION %s",
    );
    expect(migration).toContain("NOT child_index_state.indisvalid");
    expect(migration).toContain("SET lock_timeout = '5s'");
  });

  it("reuses the existing source-time index for source-wide multi-target retraction", () => {
    expect(wireSchemaMigration.replace(/\s+/g, " ")).toContain(
      "CREATE INDEX IF NOT EXISTS wire_signal_events_source_uri_idx " +
        "ON wire_signal_events (source_uri, occurred_at DESC)",
    );
    expect(normalizedMigration).not.toContain(
      "(source_uri, occurred_at DESC, canonical_key)",
    );
  });
});
