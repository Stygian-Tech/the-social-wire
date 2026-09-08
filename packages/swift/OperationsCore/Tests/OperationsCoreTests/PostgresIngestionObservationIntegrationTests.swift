import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite(
  "PostgreSQL ingestion observations",
  .enabled(
    if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database.")
)
struct PostgresIngestionObservationIntegrationTests {
  @Test("one grouped observation preserves global counts and scope while recovery state stays live")
  func groupedInboxObservation() async throws {
    let rawURL = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: rawURL))
    let logger = Logger(label: "ingestion-observation.tests")
    let pool = PostgresClient(
      configuration: .init(
        host: try #require(url.host), port: url.port ?? 5432,
        username: try #require(url.user), password: url.password,
        database: String(url.path.dropFirst()), tls: .disable), backgroundLogger: logger)
    let runner = Task { await pool.run() }
    defer { runner.cancel() }
    let environment = "dev"
    let store = PostgresOperationsStore(pool: pool, environment: environment, logger: logger)
    let now = Date()
    let oldest = now.addingTimeInterval(-100)
    let statuses = [
      "pending", "leased", "retry", "applied", "filtered_scope", "dead_letter", "dead_letter",
    ]
    for (index, status) in statuses.enumerated() {
      try await pool.query(
        """
        INSERT INTO appview_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, payload, event_time, staged_at, status, reconciled_at,
           lease_owner, lease_token, lease_expires_at, applied_at, dead_lettered_at,
           filtered_scope_policy, filtered_scope_at)
        VALUES (\(environment), \(index < 3 ? "active" : "historical"), \(index),
          'test', 'jetstream_v2_seq', 'commit', 'did:plc:test', '{}'::jsonb,
          \(oldest), \(oldest.addingTimeInterval(Double(index))), \(status),
          \(index == 6 ? now : nil as Date?),
          \(status == "leased" ? "test" : nil as String?),
          \(status == "leased" ? "test" : nil as String?),
          \(status == "leased" ? now.addingTimeInterval(60) : nil as Date?),
          \(status == "applied" ? now : nil as Date?),
          \(status == "dead_letter" ? now : nil as Date?),
          \(status == "filtered_scope" ? "test" : nil as String?),
          \(status == "filtered_scope" ? now : nil as Date?))
        """, logger: logger)
    }
    let first = try await store.fetchIngestionDurabilitySnapshot(at: now)
    #expect(
      first.inbox
        == IngestionInboxMetrics(
          pending: 1, leased: 1, retrying: 1, applied: 1, filteredScope: 1, deadLetters: 1,
          total: 7, oldestPendingAt: first.inbox.oldestPendingAt,
          oldestPendingAgeSeconds: first.inbox.oldestPendingAgeSeconds))
    #expect(abs(try #require(first.inbox.oldestPendingAgeSeconds) - 100) < 0.001)
    #expect(first.inboxBySourceGeneration["active"]?.total == 3)
    #expect(first.inboxBySourceGeneration["historical"]?.total == 4)
    #expect(first.inboxBySourceGeneration["historical"]?.oldestPendingAt == nil)

    try await pool.query(
      "UPDATE appview_ingestion_inbox SET status = 'applied', applied_at = \(now) WHERE environment = \(environment) AND status = 'pending'",
      logger: logger)
    let incident = try await store.upsertOrMergeActiveIncident(
      .init(
        sourceGeneration: "active", source: "test",
        cursorKind: .jetstreamV2Sequence, category: "test", detectedAt: now))
    let cached = try await store.fetchIngestionDurabilitySnapshot(at: now.addingTimeInterval(1))
    #expect(cached.inbox.pending == 1)
    #expect(abs(try #require(cached.inbox.oldestPendingAgeSeconds) - 101) < 0.001)
    #expect(cached.incidents.open == 1)
    let independent = PostgresOperationsStore(pool: pool, environment: environment, logger: logger)
    #expect(try await independent.fetchIngestionDurabilitySnapshot(at: now).inbox.pending == 0)
    let otherEnvironment = PostgresOperationsStore(
      pool: pool, environment: environment + "-other", logger: logger)
    #expect(try await otherEnvironment.fetchIngestionDurabilitySnapshot(at: now).inbox.total == 0)
    try await pool.query(
      "DELETE FROM appview_ingestion_inbox WHERE environment = \(environment) AND source_generation IN ('active', 'historical')",
      logger: logger)
    try await pool.query(
      "DELETE FROM appview_ingestion_incidents WHERE environment = \(environment) AND id = \(incident.id)",
      logger: logger)
  }
}
