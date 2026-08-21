import Foundation
import Testing

@Suite("The Wire migration contract")
struct WireMigrationContractTests {
  @Test("matches the durable Go inbox writer and authority tables")
  func inboxAndAuthoritySchema() throws {
    let migration = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("database/migrations/20260820120000_add_wire_discovery_feed.sql")
    let sql = try String(contentsOf: migration, encoding: .utf8)
    for token in [
      "CREATE TABLE IF NOT EXISTS wire_ingestion_inbox",
      "environment TEXT NOT NULL",
      "source_generation TEXT NOT NULL",
      "seq BIGINT NOT NULL",
      "source_host TEXT NOT NULL",
      "cursor_kind TEXT NOT NULL",
      "event_kind TEXT NOT NULL",
      "repo_did TEXT NOT NULL",
      "record_key TEXT",
      "record_cid TEXT",
      "PRIMARY KEY (environment, source_generation, seq)",
      "CREATE TABLE IF NOT EXISTS wire_signal_rollups",
      "PARTITION BY RANGE (occurred_at)",
      "ensure_wire_signal_event_partition",
      "CREATE TABLE IF NOT EXISTS wire_active_actors",
      "CREATE TABLE IF NOT EXISTS wire_follow_edges",
      "source_uri TEXT NOT NULL UNIQUE",
      "CREATE TABLE IF NOT EXISTS wire_actor_communities",
      "CREATE TABLE IF NOT EXISTS wire_labels",
      "CREATE TABLE IF NOT EXISTS wire_label_refresh_state",
      "last_successful_at TIMESTAMPTZ NOT NULL",
      "is_current BOOLEAN NOT NULL DEFAULT TRUE",
      "presentation_snapshot JSONB",
      "provenance JSONB",
    ] {
      #expect(sql.contains(token), "Migration is missing contract token: \(token)")
    }
    #expect(!sql.contains("wire_candidate_rollups"))

    let processorSource = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/WireWorker/PostgresWireInboxProcessor.swift")
    let processor = try String(contentsOf: processorSource, encoding: .utf8)
    #expect(processor.contains("earlier.repo_did = candidate.repo_did"))
    #expect(processor.contains("WITH pending_retry_candidates AS"))
    #expect(processor.contains("expired_lease_candidates AS"))
    #expect(processor.contains("ORDER BY eligible_at, seq, environment, source_generation"))
    #expect(processor.contains("candidate.environment,"))
    #expect(processor.contains("candidate.source_generation"))
    #expect(processor.contains("unresolved_publication_expired"))
    #expect(processor.contains("event.attemptCount >= 8"))
    #expect(processor.contains("DELETE FROM wire_follow_edges WHERE source_uri"))

    let publicationMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260821023000_add_wire_publication_metadata.sql")
    let publicationSQL = try String(contentsOf: publicationMigration, encoding: .utf8)
    #expect(publicationSQL.contains("CREATE TABLE IF NOT EXISTS wire_publications"))
    #expect(publicationSQL.contains("publication_uri TEXT PRIMARY KEY"))
    #expect(publicationSQL.contains("wire_publications_expires_idx"))

    let transportMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260821024500_add_wire_signal_transport_identity.sql")
    let transportSQL = try String(contentsOf: transportMigration, encoding: .utf8)
    #expect(transportSQL.contains("ADD COLUMN IF NOT EXISTS transport_event_key TEXT"))
    #expect(transportSQL.contains("wire_signal_events_transport_identity_idx"))
    #expect(transportSQL.contains("inbox.source_host"))
    #expect(transportSQL.contains("inbox.cursor_kind"))

    let lifecycleMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260821193000_bound_wire_inbox_lifecycle.sql")
    let lifecycleSQL = try String(contentsOf: lifecycleMigration, encoding: .utf8)
    #expect(lifecycleSQL.contains("CREATE TABLE IF NOT EXISTS wire_ingestion_admission"))
    #expect(lifecycleSQL.contains("ALTER COLUMN expires_at SET DEFAULT 'infinity'::timestamptz"))
    #expect(!lifecycleSQL.contains("ALTER COLUMN expires_at DROP DEFAULT"))
    #expect(lifecycleSQL.contains("fenced ingester reconciles this counter"))
    #expect(processor.contains("status IN ('applied', 'dead_letter') AND expires_at <="))
    #expect(processor.contains("asOf.addingTimeInterval(300)"))
    #expect(processor.contains("asOf.addingTimeInterval(7 * 24 * 3_600)"))
    #expect(processor.contains("SET retained_rows = GREATEST(0, retained_rows -"))

    let claimMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260821200000_optimize_wire_inbox_claim.sql")
    let claimSQL = try String(contentsOf: claimMigration, encoding: .utf8)
    #expect(claimSQL.contains("-- socialwire:transaction=off"))
    #expect(!claimSQL.contains("CONCURRENTLY"))
    #expect(claimSQL.contains("SET lock_timeout = '5s'"))
    #expect(claimSQL.contains("SET maintenance_work_mem = '1GB'"))
    #expect(claimSQL.contains("RESET maintenance_work_mem"))
    #expect(claimSQL.contains("RESET lock_timeout"))
    #expect(claimSQL.contains("DROP INDEX IF EXISTS public.wire_ingestion_inbox_claim_idx"))
    #expect(claimSQL.contains("wire_ingestion_inbox_pending_retry_ready_idx"))
    #expect(claimSQL.contains("ON public.wire_ingestion_inbox (next_attempt_at, seq)"))
    #expect(claimSQL.contains("WHERE status IN ('pending', 'retry')"))
    #expect(claimSQL.contains("wire_ingestion_inbox_expired_lease_idx"))
    #expect(claimSQL.contains("ON public.wire_ingestion_inbox (lease_expires_at, seq)"))
    #expect(claimSQL.contains("WHERE status = 'leased'"))
    let oldIndexDrop = try #require(
      claimSQL.range(of: "DROP INDEX IF EXISTS public.wire_ingestion_inbox_claim_idx"))
    let firstBuild = try #require(claimSQL.range(of: "CREATE INDEX IF NOT EXISTS"))
    #expect(oldIndexDrop.lowerBound < firstBuild.lowerBound)
  }
}
