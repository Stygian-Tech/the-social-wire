import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const migration = readFileSync(
  join(
    repositoryRoot,
    "database/migrations/20260816210000_jetstream_v2_drain_query_indexes.sql",
  ),
  "utf8",
);
const scopeFilterMigration = readFileSync(
  join(
    repositoryRoot,
    "database/migrations/20260816220000_jetstream_v2_scope_filtered_terminal.sql",
  ),
  "utf8",
);
const postgresStore = readFileSync(
  join(
    repositoryRoot,
    "packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/PostgresThinAppViewStore.swift",
  ),
  "utf8",
);
const projectionCacheStore = readFileSync(
  join(
    repositoryRoot,
    "packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/PostgresAppViewProjectionCacheStore.swift",
  ),
  "utf8",
);
const liveVerification = readFileSync(
  join(repositoryRoot, "scripts/verify-jetstream-v2-drain-indexes.sql"),
  "utf8",
);
const workflow = readFileSync(
  join(repositoryRoot, ".github/workflows/ci.yml"),
  "utf8",
);

describe("Jetstream V2 rolling-drain query indexes", () => {
  it("uses provider-neutral PostgreSQL without hosted-provider roles", () => {
    expect(migration).not.toContain("service_role");
    expect(migration).not.toContain("authenticated");
    expect(migration).not.toContain("CREATE EXTENSION");
    expect(migration).toContain("-- socialwire:transaction=off");
    expect(migration).toContain("CREATE INDEX CONCURRENTLY IF NOT EXISTS");
    expect(migration).toContain("DROP INDEX CONCURRENTLY IF EXISTS");
    expect(migration).toContain("NOT index_state.indisvalid");
  });

  it("splits ready work from expired leases using the claim predicates", () => {
    expect(migration).toContain(
      "idx_appview_ingestion_inbox_ready",
    );
    expect(migration).toContain(
      "(environment, source_generation, next_attempt_at, seq)",
    );
    expect(migration).toContain("WHERE status IN ('pending', 'retry')");
    expect(migration).toContain(
      "idx_appview_ingestion_inbox_expired_lease",
    );
    expect(migration).toContain(
      "(environment, source_generation, lease_expires_at, seq)",
    );
    expect(migration).toContain("WHERE status = 'leased'");

    expect(postgresStore).toContain(
      "i.status IN ('pending', 'retry') AND i.next_attempt_at <=",
    );
    expect(postgresStore).toContain(
      "i.status = 'leased' AND i.lease_expires_at <=",
    );
  });

  it("indexes generation-scoped reconciliation blocking and FIFO", () => {
    expect(migration).toContain(
      "idx_appview_ingestion_reconciliation_ready",
    );
    expect(migration).toContain(
      "(environment, source_generation, next_attempt_at, trigger_seq, id)",
    );
    expect(migration).toContain(
      "idx_appview_ingestion_reconciliation_expired_lease",
    );
    expect(migration).toContain(
      "(environment, source_generation, lease_expires_at, trigger_seq, id)",
    );
    expect(migration).toContain(
      "idx_appview_ingestion_reconciliation_active_repo",
    );
    expect(migration).toContain(
      "(environment, source_generation, repo_did, trigger_seq)",
    );
    expect(migration).toContain("WHERE status IN ('pending', 'leased')");

    expect(postgresStore).toContain(
      "request.source_generation = i.source_generation",
    );
    expect(postgresStore).toContain("request.repo_did = i.repo_did");
    expect(postgresStore).toContain(
      "earlier.source_generation = request.source_generation",
    );
    expect(postgresStore).toContain("earlier.repo_did = request.repo_did");
    expect(postgresStore).toContain(
      "request.status = 'pending' AND request.next_attempt_at <=",
    );
    expect(postgresStore).toContain(
      "request.status = 'leased' AND request.lease_expires_at <=",
    );
  });

  it("matches the first nonterminal watermark barrier exactly", () => {
    expect(scopeFilterMigration).toContain(
      "idx_appview_ingestion_inbox_terminal_barrier_v2",
    );
    expect(scopeFilterMigration).toContain(
      "ON appview_ingestion_inbox (environment, source_generation, seq)",
    );
    expect(scopeFilterMigration).toContain(
      "WHERE status NOT IN ('applied', 'filtered_scope') AND reconciled_at IS NULL",
    );
    expect(postgresStore).toContain(
      "AND status NOT IN ('applied', 'filtered_scope') AND reconciled_at IS NULL",
    );
  });

  it("adds the publication-first cache invalidation path", () => {
    expect(migration).toContain(
      "idx_first_page_cache_publication_viewer",
    );
    expect(migration).toContain(
      "ON first_page_cache (publication_id, viewer_did)",
    );
    expect(projectionCacheStore).toContain(
      '"DELETE FROM first_page_cache WHERE publication_id = \\(publicationId)"',
    );
  });

  it("keeps migration verification centralized while wiring guarded Swift Postgres tests", () => {
    for (const indexName of [
      "idx_appview_ingestion_inbox_ready",
      "idx_appview_ingestion_inbox_expired_lease",
      "idx_appview_ingestion_reconciliation_ready",
      "idx_appview_ingestion_reconciliation_expired_lease",
      "idx_appview_ingestion_reconciliation_active_repo",
      "idx_appview_ingestion_inbox_terminal_barrier",
      "idx_appview_ingestion_inbox_terminal_barrier_v2",
      "idx_first_page_cache_publication_viewer",
    ]) {
      expect(liveVerification).toContain(indexName);
    }
    expect(liveVerification).toContain("EXPLAIN (COSTS OFF)");
    expect(liveVerification).toContain("assert_plan_uses_all");
    expect(liveVerification).toContain("FOR UPDATE SKIP LOCKED");
    expect(liveVerification).toContain(
      "Exercise the corresponding representative reconciliation claim shape",
    );
    const charybdisJob = workflow.slice(
      workflow.indexOf("  charybdis:"),
      workflow.indexOf("\n  operations:"),
    );
    const databaseJob = workflow.slice(
      workflow.indexOf("  database-migrator:"),
      workflow.indexOf("\n  lexicons:"),
    );
    expect(charybdisJob).toContain("postgres:17-alpine");
    expect(charybdisJob).toContain("POSTGRES_DB: thin_appview_test");
    expect(charybdisJob).toContain("THIN_APPVIEW_TEST_DATABASE_URL:");
    expect(charybdisJob).not.toContain("the-social-wire-database-migrator:test");
    expect(databaseJob).toContain("Verify Jetstream V2 drain indexes and query plans");
    expect(databaseJob).toContain("verify-jetstream-v2-drain-indexes.sql");
  });
});
