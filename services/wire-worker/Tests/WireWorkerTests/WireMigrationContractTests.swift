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
    #expect(processor.contains("let claimLimit = Self.boundedClaimLimit"))
    #expect(processor.components(separatedBy: "LIMIT \\(claimLimit)").count == 4)
    #expect(processor.contains("candidate.environment,"))
    #expect(processor.contains("candidate.source_generation"))
    #expect(processor.contains("unresolved_publication_expired"))
    #expect(processor.contains("event.attemptCount >= 8"))
    #expect(processor.contains("DELETE FROM wire_follow_edges WHERE source_uri"))
    #expect(processor.contains("Self.isSelfFollow(follower: follower, followee: followee)"))
    #expect(processor.contains("pg_advisory_xact_lock(hashtext('wire_signal_rollups_refresh')::bigint)"))
    #expect(processor.contains("TRUNCATE TABLE wire_signal_rollups"))
    #expect(!processor.contains("\"DELETE FROM wire_signal_rollups\""))
    #expect(processor.contains("func acknowledgeUnresolvedPassiveReferences"))
    #expect(processor.contains("candidate.event_kind = 'commit'"))
    #expect(
      processor.contains(
        "candidate.collection IN ('app.bsky.feed.like', 'app.bsky.feed.repost')"))
    #expect(processor.contains("candidate.operation IN ('create', 'update')"))
    #expect(processor.contains("candidate.payload #>> '{commit,record,subject,uri}'"))
    #expect(processor.contains("alias.expires_at > \\(asOf)"))
    #expect(processor.contains("FOR UPDATE SKIP LOCKED"))
    #expect(processor.contains("AND inbox.status IN ('pending', 'retry')"))
    #expect(
      processor.contains("let fastPathCount = try await acknowledgeUnresolvedPassiveReferences"))
    #expect(processor.contains("return fastPathCount + events.count"))

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

    let unloggedMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260823190000_make_wire_hot_path_unlogged.sql")
    let unloggedSQL = try String(contentsOf: unloggedMigration, encoding: .utf8)
    for token in [
      "LOCK TABLE wire_ingestion_inbox IN ACCESS EXCLUSIVE MODE",
      "CREATE UNLOGGED TABLE wire_ingestion_inbox_unlogged",
      "WHERE status IN ('pending', 'leased', 'retry')",
      "SET status = 'retry'",
      "DROP TABLE wire_ingestion_inbox",
      "ALTER TABLE wire_ingestion_inbox_unlogged RENAME TO wire_ingestion_inbox",
      "wire_ingestion_inbox_pending_retry_ready_idx",
      "wire_ingestion_inbox_expired_lease_idx",
      "wire_ingestion_inbox_repo_fifo_idx",
      "CREATE UNLOGGED TABLE IF NOT EXISTS wire_ingestion_inbox_epochs",
      "CREATE TABLE IF NOT EXISTS wire_ingestion_recovery_anchors",
      "checkpoint.source_generation LIKE 'wire-%'",
      "CREATE UNLOGGED TABLE %I PARTITION OF wire_signal_events",
      "ALTER TABLE wire_signal_rollups SET UNLOGGED",
      "ALTER TABLE wire_active_actors SET UNLOGGED",
      "ALTER TABLE wire_follow_edges SET UNLOGGED",
      "ALTER TABLE wire_actor_communities SET UNLOGGED",
      "ALTER TABLE wire_item_mentions SET UNLOGGED",
      "ALTER TABLE wire_article_feedback SET UNLOGGED",
      "'wire_ranked_items'",
      "must remain LOGGED",
    ] {
      #expect(unloggedSQL.contains(token), "UNLOGGED migration is missing: \(token)")
    }
    #expect(!unloggedSQL.contains("ALTER TABLE wire_ranked_items SET UNLOGGED"))

    let anchorRepairMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260823210000_repair_wire_recovery_anchor_tuples.sql")
    let anchorRepairSQL = try String(contentsOf: anchorRepairMigration, encoding: .utf8)
    #expect(anchorRepairSQL.contains("CREATE TEMP TABLE wire_anchor_evidence"))
    #expect(anchorRepairSQL.contains("DELETE FROM wire_ingestion_recovery_anchors anchor"))
    #expect(anchorRepairSQL.contains("checkpoint_seq,\n         anchor.checkpoint_event_time"))
    #expect(anchorRepairSQL.contains("ORDER BY environment, source_generation, seq, event_time"))
    #expect(anchorRepairSQL.contains("Wire epoch has no exact recovery anchor"))

    let ingestStore = migration.deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("services/jetstream-ingest/internal/store/postgres.go")
    let ingestStoreSource = try String(contentsOf: ingestStore, encoding: .utf8)
    #expect(ingestStoreSource.contains("WHEN EXCLUDED.checkpoint_seq"))
    #expect(
      ingestStoreSource.contains(
        "THEN EXCLUDED.checkpoint_event_time\n\t\t\t        ELSE wire_ingestion_recovery_anchors.checkpoint_event_time"))
    #expect(!ingestStoreSource.contains("checkpoint_event_time = LEAST("))

    let qualityIndexMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260822212900_prepare_wire_quality_ranking_index.sql")
    let qualityIndexSQL = try String(contentsOf: qualityIndexMigration, encoding: .utf8)
    #expect(qualityIndexSQL.contains("-- socialwire:transaction=off"))
    #expect(qualityIndexSQL.contains("SET lock_timeout = '5s'"))
    #expect(qualityIndexSQL.contains("CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_signal_rollups_high_intent_rank_idx"))
    #expect(qualityIndexSQL.contains("RESET lock_timeout"))

    let qualityMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260822213000_tune_wire_quality_ranking.sql")
    let qualitySQL = try String(contentsOf: qualityMigration, encoding: .utf8)
    #expect(qualitySQL.contains("wire_signal_rollups_high_intent_rank_idx"))
    #expect(qualitySQL.contains("rollup.shares_24h >= 3"))
    #expect(qualitySQL.contains("item.provenance ? 'standard_site'"))
    #expect(qualitySQL.contains("metadata.source = 'open_graph'"))
    #expect(qualitySQL.contains("metadata.stale_until > CURRENT_TIMESTAMP"))
    #expect(!qualitySQL.contains("distinct_actors_24h"))

    let feedbackMigration = migration.deletingLastPathComponent()
      .appendingPathComponent("20260822220000_add_wire_article_feedback.sql")
    let feedbackSQL = try String(contentsOf: feedbackMigration, encoding: .utf8)
    #expect(feedbackSQL.contains("CREATE TABLE IF NOT EXISTS wire_article_feedback"))
    #expect(feedbackSQL.contains("PRIMARY KEY (canonical_key, actor_key_hash)"))
    #expect(feedbackSQL.contains("source_uri TEXT NOT NULL UNIQUE"))
    #expect(feedbackSQL.contains("positive_feedback_24h"))
    #expect(feedbackSQL.contains("negative_feedback_24h"))
    #expect(!feedbackSQL.contains("repo_did"))

    #expect(processor.contains("case \"app.thesocialwire.wireFeedback\""))
    #expect(processor.contains("COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'recommendation'"))
    #expect(processor.contains("DELETE FROM wire_article_feedback WHERE source_uri"))
  }
}
