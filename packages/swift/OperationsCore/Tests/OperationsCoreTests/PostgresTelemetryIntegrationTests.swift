import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite(
  "Operations PostgreSQL telemetry",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database."
  )
)
struct PostgresTelemetryIntegrationTests {
  @Test("coalesced writes retain count sum extrema and separate minute and dimension keys")
  func coalescedStatistics() async throws {
    try await withStore { store, pool, logger in
      let name = "coalesced.\(UUID().uuidString)"
      let minute = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
      func metric(_ value: Double, offset: Double = 0, lane: String = "a")
        -> OperationsTelemetrySignal
      {
        .metric(
          .init(
            name: name, value: value, dimensions: ["environment": "prod", "lane": lane],
            recordedAt: minute.addingTimeInterval(offset)))
      }
      try await store.recordTelemetryBatch([
        metric(4), metric(-2, offset: 3), metric(10, offset: 59),
        metric(20, offset: 60), metric(40, lane: "b"),
      ])
      try await store.recordTelemetryBatch([metric(2), metric(6)])
      let rows = try await pool.query(
        """
        SELECT bucket_start, dimensions->>'lane', sample_count, value_sum, value_min, value_max
        FROM operations_metric_rollups WHERE environment = 'prod' AND metric_name = \(name)
        ORDER BY bucket_start, dimensions->>'lane'
        """, logger: logger)
      var values: [(Date, String, Int64, Double, Double, Double)] = []
      for try await row in rows {
        values.append(try row.decode((Date, String, Int64, Double, Double, Double).self))
      }
      #expect(values.count == 3)
      let primary = try #require(values.first)
      #expect(primary.0 == minute && primary.1 == "a")
      #expect(primary.2 == 5 && primary.3 == 20 && primary.4 == -2 && primary.5 == 10)
      #expect(values[1].2 == 1 && values[1].3 == 40)
      #expect(values[2].0 == minute.addingTimeInterval(60) && values[2].3 == 20)
    }
  }

  @Test("concurrent writers use the same lock order and retain every coalesced sample")
  func concurrentWriters() async throws {
    try await withStore { _, pool, logger in
      let prefix = "concurrent.\(UUID().uuidString)"
      let now = Date()
      let firstName = "\(prefix).a"
      let secondName = "\(prefix).b"
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        for index in 0..<8 {
          tasks.addTask {
            let store = PostgresOperationsStore(pool: pool, environment: "prod", logger: logger)
            let names =
              index.isMultiple(of: 2) ? [firstName, secondName] : [secondName, firstName]
            let samples = names.flatMap { name in
              (1...25).map { value in
                OperationsTelemetrySignal.metric(
                  .init(
                    name: name, value: Double(value), dimensions: ["environment": "prod"],
                    recordedAt: now))
              }
            }
            try await store.recordTelemetryBatch(samples)
          }
        }
        try await tasks.waitForAll()
      }
      let rows = try await pool.query(
        """
        SELECT sample_count, value_sum, value_min, value_max
        FROM operations_metric_rollups
        WHERE environment = 'prod' AND metric_name = ANY(\([firstName, secondName])::text[])
        """, logger: logger)
      var count = 0
      for try await row in rows {
        let value = try row.decode((Int64, Double, Double, Double).self)
        #expect(value.0 == 200 && value.1 == 2600 && value.2 == 1 && value.3 == 25)
        count += 1
      }
      #expect(count == 2)
    }
  }

  @Test("environment validation rejects a whole mixed batch before any metric event or span writes")
  func environmentValidationIsAtomic() async throws {
    try await withStore { store, pool, logger in
      let name = "validation.\(UUID().uuidString)"
      let valid = OperationsTelemetrySignal.metric(
        .init(
          name: name, value: 1, dimensions: ["environment": "prod"]))
      let invalidSignals: [OperationsTelemetrySignal] = [
        .metric(.init(name: name, value: 1, dimensions: ["environment": "dev"])),
        .event(.init(service: "test", environment: "dev", instanceId: "test", name: name)),
        .span(
          .init(
            environment: "dev", traceId: "test", service: "test", name: name,
            startedAt: Date(), durationMs: 1, status: "ok", attributes: [:],
            expiresAt: Date().addingTimeInterval(3600))),
      ]
      for invalid in invalidSignals {
        await #expect(throws: OperationsStoreError.self) {
          try await store.recordTelemetryBatch([valid, invalid])
        }
      }
      let rows = try await pool.query(
        "SELECT COUNT(*)::bigint FROM operations_metric_rollups WHERE metric_name = \(name)",
        logger: logger)
      for try await row in rows { #expect(try row.decode(Int64.self) == 0) }
    }
  }

  @Test(
    "catalog counters write bounded metrics once per minute and compute WAL rate only after a baseline"
  )
  func costSampling() async throws {
    try await withStore { store, pool, logger in
      try await pool.query(
        "DELETE FROM operations_metric_rollups WHERE environment = 'prod' AND metric_name LIKE 'socialwire.database.%'",
        logger: logger)
      let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
      async let first: Void = store.recordDatabaseCostTelemetry(at: now)
      async let duplicate: Void = store.recordDatabaseCostTelemetry(at: now)
      _ = await (first, duplicate)
      let baseline = try await metricCounts(pool: pool, logger: logger)
      #expect(baseline["socialwire.database.wal_bytes_total"] == 1)
      #expect(baseline["socialwire.database.statement_execution_ms_total"] == 1)
      #expect(baseline["socialwire.database.wal_bytes_per_second"] == nil)
      #expect(baseline.count <= 16)
      await store.recordDatabaseCostTelemetry(at: now.addingTimeInterval(59))
      #expect(try await metricCounts(pool: pool, logger: logger) == baseline)
      await store.recordDatabaseCostTelemetry(at: now.addingTimeInterval(60))
      let subsequent = try await metricCounts(pool: pool, logger: logger)
      #expect(subsequent["socialwire.database.wal_bytes_total"] == 2)
      #expect(subsequent["socialwire.database.wal_bytes_per_second"] == 1)
      let rows = try await pool.query(
        """
        SELECT COUNT(*)::bigint, MAX(sample_count), BOOL_AND(dimensions->>'environment' = 'prod')
        FROM operations_metric_rollups WHERE environment = 'prod' AND metric_name LIKE 'socialwire.database.%'
        """, logger: logger)
      for try await row in rows {
        let value = try row.decode((Int64, Int64, Bool).self)
        #expect(value.0 <= 160 && value.1 == 1 && value.2)
      }
    }
  }

  @Test("expiry counts stop at a bounded prefix and distinguish exact empty and truncated samples")
  func expiryBacklogSampling() async throws {
    try await withStore { store, pool, logger in
      let prefix = UUID().uuidString
      let cutoff = Date(timeIntervalSince1970: 1_000_000)
      for index in 0..<5 {
        try await pool.query(
          """
          INSERT INTO appview_circle_edition_cache
            (viewer_key_hash, snapshot_id, generation_id, language_code, expires_at, payload)
          VALUES (\(prefix + String(index)), \(UUID()), 'test', 'en',
            \(cutoff.addingTimeInterval(index < 4 ? -1 : 60)), '{}'::jsonb)
          """, logger: logger)
      }
      func circleSample() async throws -> (Int64, Bool) {
        let rows = try await store.databaseExpiryBacklogRows(at: cutoff, sampleLimit: 2)
        #expect(rows.count == 10)
        for row in rows {
          let value = try row.decode((String, Int64, Bool).self)
          if value.0 == "appview_circle_edition_cache" { return (value.1, value.2) }
        }
        Issue.record("Circle expiry sample missing")
        return (-1, false)
      }
      let capped = try await circleSample()
      #expect(capped.0 == 3 && capped.1)  // Reads only limit + 1, not all four expired rows.
      try await pool.query(
        "DELETE FROM appview_circle_edition_cache WHERE viewer_key_hash = ANY(\([prefix + "0", prefix + "1"])::text[])",
        logger: logger)
      let exact = try await circleSample()
      #expect(exact.0 == 2 && !exact.1)
      try await pool.query(
        "DELETE FROM appview_circle_edition_cache WHERE viewer_key_hash = ANY(\([prefix + "2", prefix + "3"])::text[])",
        logger: logger)
      let empty = try await circleSample()
      #expect(empty.0 == 0 && !empty.1)  // The unexpired fifth row is not counted.
      try await pool.query(
        "DELETE FROM appview_circle_edition_cache WHERE viewer_key_hash = \(prefix + "4")",
        logger: logger)
    }
  }

  @Test(
    "bounded inbox samples count terminal cleanup rows and preserve recovery and environment boundaries"
  )
  func inboxExpirySampling() async throws {
    try await withStore { store, pool, logger in
      let generation = UUID().uuidString
      let cutoff = Date(timeIntervalSince1970: 2_000_000)
      for (index, status) in [
        "pending", "retry", "dead_letter", "applied", "filtered_scope", "dead_letter",
      ].enumerated() {
        try await pool.query(
          """
          INSERT INTO appview_ingestion_inbox
            (environment, source_generation, seq, source_host, cursor_kind, event_kind,
             repo_did, payload, event_time, status, applied_at, dead_lettered_at, reconciled_at, expires_at,
             filtered_scope_policy, filtered_scope_at)
          VALUES ('prod', \(generation), \(index), 'test', 'jetstream_v2_seq', 'commit',
            'did:plc:test', '{}'::jsonb, \(cutoff), \(status),
            \(status == "applied" ? cutoff : nil as Date?), \(cutoff),
            \(index == 5 ? cutoff : nil as Date?), \(cutoff.addingTimeInterval(Double(index - 10))),
            \(status == "filtered_scope" ? "test" : nil as String?),
            \(status == "filtered_scope" ? cutoff : nil as Date?))
          """, logger: logger)
      }
      for row in try await store.databaseExpiryBacklogRows(at: cutoff, sampleLimit: 2) {
        let sample = try row.decode((String, Int64, Bool).self)
        if sample.0 == "appview_ingestion_inbox" {
          #expect(sample.1 == 0 && sample.2)  // Full protected prefix is not an empty backlog.
        }
      }
      for row in try await store.databaseExpiryBacklogRows(at: cutoff, sampleLimit: 10) {
        let sample = try row.decode((String, Int64, Bool).self)
        if sample.0 == "appview_ingestion_inbox" {
          #expect(sample.1 == 3 && !sample.2)
        }
      }
      let other = PostgresOperationsStore(pool: pool, environment: "dev", logger: logger)
      for row in try await other.databaseExpiryBacklogRows(at: cutoff, sampleLimit: 10) {
        let sample = try row.decode((String, Int64, Bool).self)
        if sample.0 == "appview_ingestion_inbox" { #expect(sample.1 == 0 && !sample.2) }
      }
      try await pool.query(
        "DELETE FROM appview_ingestion_inbox WHERE source_generation = \(generation)",
        logger: logger)
    }
  }

  @Test("generation duration emits valid active timing and omits missing and malformed diagnostics")
  func generationDurationSampling() async throws {
    try await withStore { store, pool, logger in
      let prefix = "test-\(UUID().uuidString.lowercased())"
      let now = Date()
      for (suffix, diagnostic) in [
        ("valid", #"{"cycleDurationMilliseconds":1234.5}"#),
        ("missing", "{}"),
        ("invalid", #"{"cycleDurationMilliseconds":"NaN"}"#),
      ] {
        try await pool.query(
          """
          INSERT INTO wire_rank_generations
            (generation_id, feed_key, language_bucket, status, is_active, config_version,
             generated_at, committed_at, expires_at, diagnostics)
          VALUES (\(UUID()), 'wire', \(prefix + suffix), 'committed', TRUE, 'test',
            \(now), \(now), \(now.addingTimeInterval(3600)), \(diagnostic)::jsonb)
          """, logger: logger)
      }
      await store.recordDatabaseCostTelemetry(at: now)
      let rows = try await pool.query(
        """
        SELECT dimensions->>'language', value_sum, sample_count
        FROM operations_metric_rollups WHERE environment = 'prod'
          AND metric_name = 'socialwire.wire.generation_duration_ms'
          AND dimensions->>'language' LIKE \(prefix + "%")
        """, logger: logger)
      var count = 0
      for try await row in rows {
        let value = try row.decode((String, Double, Int64).self)
        #expect(value.0 == prefix + "valid" && value.1 == 1234.5 && value.2 == 1)
        count += 1
      }
      #expect(count == 1)
      try await pool.query(
        "DELETE FROM wire_rank_generations WHERE language_bucket LIKE \(prefix + "%")",
        logger: logger)
    }
  }

  @Test("a slow cost query times out and its local timeout does not leak into the connection pool")
  func boundedCostQuery() async throws {
    try await withStore { store, pool, logger in
      let started = ContinuousClock.now
      await #expect(throws: (any Error).self) {
        _ = try await store.databaseCostRows("SELECT pg_sleep(10)")
      }
      #expect(started.duration(to: .now) < .seconds(8))
      try await store.ping()
      let rows = try await pool.query("SHOW statement_timeout", logger: logger)
      for try await row in rows { #expect(try row.decode(String.self) == "0") }
    }
  }

  private func metricCounts(pool: PostgresClient, logger: Logger) async throws -> [String: Int64] {
    let rows = try await pool.query(
      """
      SELECT metric_name, SUM(sample_count)::bigint FROM operations_metric_rollups
      WHERE environment = 'prod' AND metric_name LIKE 'socialwire.database.%'
      GROUP BY metric_name
      """, logger: logger)
    var values: [String: Int64] = [:]
    for try await row in rows {
      let value = try row.decode((String, Int64).self)
      values[value.0] = value.1
    }
    return values
  }

  private func withStore(
    _ body: (PostgresOperationsStore, PostgresClient, Logger) async throws -> Void
  ) async throws {
    let rawURL = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: rawURL))
    let host = try #require(url.host)
    let username = try #require(url.user)
    let logger = Logger(label: "operations-postgres-telemetry.tests")
    var config = PostgresClient.Configuration(
      host: host, port: url.port ?? 5432, username: username, password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 4
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    try await body(
      PostgresOperationsStore(pool: pool, environment: "prod", logger: logger), pool, logger)
  }
}
