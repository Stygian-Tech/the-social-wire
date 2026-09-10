import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite("PostgreSQL generation health", .serialized, .enabled(
  if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
  "Requires an explicitly disposable migrated PostgreSQL database."))
struct PostgresIngestionHealthIntegrationTests {
  @Test("live health matches actionable census fields, includes delayed work, and isolates generations")
  func actionableParity() async throws {
    try await withFixture { store, pool, logger, environment in
      let now = Date(timeIntervalSince1970: 1_800_000_000)
      for generation in ["active", "retired"] {
        try await pool.query("""
          INSERT INTO appview_jetstream_checkpoints
            (environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,replay_state,updated_at)
          VALUES (\(environment),\(generation),'test','test','test','jetstream_v2_seq','live',\(now))
          """, logger: logger)
      }
      let statuses = ["pending", "leased", "retry", "applied", "filtered_scope", "dead_letter", "dead_letter"]
      for generation in ["active", "retired"] {
        for (index, status) in statuses.enumerated() {
          try await pool.query("""
            INSERT INTO appview_ingestion_inbox
              (environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,
               staged_at,status,next_attempt_at,lease_owner,lease_token,lease_expires_at,applied_at,
               dead_lettered_at,reconciled_at,filtered_scope_policy,filtered_scope_at)
            VALUES (\(environment),\(generation),\(index),'test','jetstream_v2_seq','commit','did:plc:test','{}'::jsonb,
              \(now),\(now.addingTimeInterval(Double(-index - 1))),\(status),\(now.addingTimeInterval(3600)),
              \(status == "leased" ? "owner" : nil as String?),\(status == "leased" ? "token" : nil as String?),
              \(status == "leased" ? now.addingTimeInterval(3600) : nil as Date?),
              \(status == "applied" ? now : nil as Date?),\(status == "dead_letter" ? now : nil as Date?),
              \(index == 6 ? now : nil as Date?),\(status == "filtered_scope" ? "test" : nil as String?),
              \(status == "filtered_scope" ? now : nil as Date?))
            """, logger: logger)
        }
      }
      let census = try await store.fetchIngestionDurabilitySnapshot(at: now)
      let health = try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now)
      let old = try #require(census.inboxBySourceGeneration["active"])
      #expect(health.pending == old.pending && health.leased == old.leased && health.retrying == old.retrying)
      #expect(health.deadLetters == old.deadLetters && health.deadLetters == 1)
      #expect(health.oldestPendingAt == old.oldestPendingAt && health.oldestPendingAt == now.addingTimeInterval(-3))
      #expect(health.checkpoint?.sourceGeneration == "active" && health.checkpoint?.intakeHeartbeatAt == nil)
      #expect(census.inbox.total == 14)
      let lease = try #require(try await store.acquireIngestionLeaderLease(
        name: "health", sourceGeneration: "active", ownerID: "worker", leaseUntil: now.addingTimeInterval(30), at: now))
      #expect(try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now.addingTimeInterval(30)).checkpoint?.intakeHeartbeatAt == now)
      #expect(try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now.addingTimeInterval(31)).checkpoint?.intakeHeartbeatAt == nil)
      try await store.releaseIngestionLeaderLease(name: "health", ownerID: "worker", fencingToken: lease.fencingToken, at: now)
      #expect(try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now).checkpoint?.intakeHeartbeatAt == nil)
      try await pool.query("UPDATE appview_ingestion_inbox SET status='applied',applied_at=\(now) WHERE environment=\(environment) AND source_generation='active' AND status='pending'", logger: logger)
      #expect(try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now).pending == 0)
      let missing = try await store.fetchIngestionGenerationHealth(sourceGeneration: "missing", at: now)
      #expect(missing.checkpoint == nil && missing.pending == 0 && missing.deadLetters == 0 && missing.oldestPendingAt == nil)
      let other = PostgresOperationsStore(pool: pool, environment: environment + "-other", logger: logger)
      #expect(try await other.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now).checkpoint == nil)
      #expect(try await other.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now).pending == 0)
    }
  }

  @Test("100000 retained terminal rows do not enter the live-health scan")
  func retainedHistoryPlan() async throws {
    try await withFixture { store, pool, logger, environment in
      let now = Date(timeIntervalSince1970: 1_800_000_000)
      try await pool.query("""
        INSERT INTO appview_ingestion_inbox
          (environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,staged_at)
        VALUES (\(environment),'active',1,'test','jetstream_v2_seq','commit','did:plc:test','{}'::jsonb,\(now),'pending',\(now))
        """, logger: logger)
      func plan() async throws -> (Int, [String]) {
        let query = PostgresOperationsStore.ingestionGenerationHealthQuery(environment: environment, sourceGeneration: "active", at: now)
        let rows = try await pool.query(PostgresQuery(unsafeSQL: "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + query.sql, binds: query.binds), logger: logger)
        var json = ""
        for try await row in rows { json = try row.decode(String.self) }
        let array = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let root = try #require(array.first?["Plan"] as? [String: Any])
        var inboxAccess: [String] = []
        func visit(_ node: [String: Any]) {
          if node["Relation Name"] as? String == "appview_ingestion_inbox" {
            inboxAccess.append(node["Node Type"] as? String ?? "unknown")
          }
          for child in node["Plans"] as? [[String: Any]] ?? [] { visit(child) }
        }
        visit(root)
        return ((root["Shared Hit Blocks"] as? Int ?? 0) + (root["Shared Read Blocks"] as? Int ?? 0), inboxAccess)
      }
      let before = try await plan()
      try await pool.query("""
        INSERT INTO appview_ingestion_inbox
          (environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,applied_at)
        SELECT \(environment),CASE WHEN n%2=0 THEN 'active' ELSE 'retired' END,n,'test','jetstream_v2_seq','commit',
          'did:plc:terminal','{}'::jsonb,\(now),'applied',\(now) FROM generate_series(1000,100999) n
        """, logger: logger)
      try await pool.query("ANALYZE appview_ingestion_inbox", logger: logger)
      let after = try await plan()
      #expect(!after.1.isEmpty && after.1.allSatisfy { $0.contains("Index") || $0 == "Bitmap Heap Scan" })
      #expect(after.0 <= before.0 + 100)
      #expect(try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: now).pending == 1)
      print("Ingestion health retained-history plan: before=\(before.0) blocks after=\(after.0) blocks, access=\(after.1)")
    }
  }

  @Test("blocked live observations time out, remain unavailable, and do not leak pooled timeout settings")
  func queryFailure() async throws {
    try await withFixture { store, pool, logger, _ in
      try await pool.withTransaction(logger: logger) { blocker in
        try await blocker.query("LOCK TABLE appview_jetstream_checkpoints IN ACCESS EXCLUSIVE MODE", logger: logger)
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
          _ = try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: Date())
        }
        #expect(started.duration(to: .now) < .seconds(5))
      }
      #expect(try await store.fetchIngestionGenerationHealth(sourceGeneration: "active", at: Date()).pending == 0)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
          group.addTask {
            try await pool.withConnection { connection in
              for try await row in try await connection.query("SHOW statement_timeout", logger: logger) {
                #expect(try row.decode(String.self) == "0")
              }
            }
          }
        }
        try await group.waitForAll()
      }
    }
  }

  private func withFixture(_ body: (PostgresOperationsStore, PostgresClient, Logger, String) async throws -> Void) async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: raw)), environment = "health-" + UUID().uuidString
    let logger = Logger(label: "ingestion-health.tests")
    var config = PostgresClient.Configuration(host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password, database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 4
    let admin = PostgresClient(configuration: config, backgroundLogger: logger)
    let adminRunner = Task { await admin.run() }
    defer { adminRunner.cancel() }
    let schema = "health_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try await admin.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA " + schema), logger: logger)
    do {
      // Clone reviewed migrated columns, constraints and indexes, but no shared rows.
      // Schema isolation prevents the lock timeout and plan-size fixture from affecting
      // other suites; the pool cannot fall back to public tables through search_path.
      for table in ["appview_ingestion_inbox", "appview_jetstream_checkpoints", "appview_ingestion_leases",
        "appview_ingestion_incidents", "appview_ingestion_replay_usage"] {
        try await admin.query(PostgresQuery(unsafeSQL:
          "CREATE TABLE " + schema + "." + table + " (LIKE public." + table + " INCLUDING ALL)"), logger: logger)
      }
      config.options.additionalStartupParameters = [("search_path", schema)]
      let pool = PostgresClient(configuration: config, backgroundLogger: logger)
      let runner = Task { await pool.run() }
      do {
        try await body(PostgresOperationsStore(pool: pool, environment: environment, logger: logger), pool, logger, environment)
      } catch {
        runner.cancel()
        await runner.value
        throw error
      }
      runner.cancel()
      await runner.value
    } catch {
      _ = try? await admin.query(PostgresQuery(unsafeSQL: "DROP SCHEMA " + schema + " CASCADE"), logger: logger)
      throw error
    }
    try await admin.query(PostgresQuery(unsafeSQL: "DROP SCHEMA " + schema + " CASCADE"), logger: logger)
  }
}
