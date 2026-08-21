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
    #expect(processor.contains("event.attemptCount >= 8"))
    #expect(processor.contains("DELETE FROM wire_follow_edges WHERE source_uri"))
  }
}
