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
  @Test("a blocked event does not hold shared metric keys and rolled-back telemetry survives retry exhaustion")
  func blockedEventDoesNotBlockMetrics() async throws {
    try await withStore { store, pool, logger in
      let name = "identity-lock.\(UUID().uuidString)"
      let at = Date()
      let metric = OperationsTelemetrySignal.metric(.init(
        name: name, value: 7, dimensions: [:], recordedAt: at))
      let event = OperationsTelemetrySignal.event(.init(
        id: name, service: "test", environment: "prod", instanceId: "test", name: name))
      let buffer = OperationsTelemetryBuffer(
        store: store, capacity: 3, batchSize: 2, maxRetryAttempts: 1, logger: logger)
      #expect(await buffer.enqueue(metric))
      #expect(await buffer.enqueue(event))
      try await pool.withTransaction(logger: logger) { blocker in
        try await blocker.query(
          """
          INSERT INTO operations_events
            (id, service, environment, instance_id, event_name, occurred_at, attributes, expires_at)
          VALUES (\(name), 'test', 'prod', 'test', \(name), \(at), '{}'::jsonb,
            \(at.addingTimeInterval(86400)))
          """, logger: logger)
        let flush = Task { await buffer.flushOnce() }
        var waiting = false
        for _ in 0..<30 {
          let rows = try await pool.query(
            """
            SELECT EXISTS (SELECT 1 FROM pg_stat_activity
              WHERE datname = current_database() AND wait_event_type = 'Lock'
                AND query LIKE '%INSERT INTO operations_events%')
            """, logger: logger)
          for try await row in rows { waiting = try row.decode(Bool.self) }
          if waiting { break }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(waiting)
        // This fails with the former metrics-first transaction: its rollup key is
        // locked until the unrelated event insert times out half a second later.
        try await store.recordTelemetryBatch([metric], statementTimeoutMilliseconds: 100)
        #expect(await buffer.enqueue(metric))
        #expect(await flush.value == 0)
        let deferred = await buffer.snapshot()
        #expect(deferred.queueDepth == 3 && deferred.inFlightCount == 0)
        #expect(deferred.droppedCount == 0 && deferred.consecutiveFailures == 1)
        #expect(deferred.lastSuccessfulExportAt == nil)
        // Exhaustion yields instead of immediately hammering the same lock again.
        #expect(await buffer.flushOnce() == 0)
      }
      #expect(await buffer.flushOnce(at: .now.advanced(by: .seconds(6))) == 2)
      #expect(await buffer.flushOnce() == 1)
      let recovered = await buffer.snapshot()
      #expect(recovered.queueDepth == 0 && recovered.droppedCount == 0)
      #expect(recovered.consecutiveFailures == 0 && recovered.lastSuccessfulExportAt != nil)
      let rows = try await pool.query(
        """
        SELECT sample_count, value_sum,
          (SELECT COUNT(*) FROM operations_events WHERE environment = 'prod' AND id = \(name))
        FROM operations_metric_rollups WHERE environment = 'prod' AND metric_name = \(name)
        """, logger: logger)
      var found = false
      for try await row in rows {
        let value = try row.decode((Int64, Double, Int64).self)
        #expect(value.0 == 3 && value.1 == 21 && value.2 == 1)
        found = true
      }
      #expect(found)
    }
  }

  @Test("permanent database errors are not deferred even after a successful rollback")
  func permanentFailureIsNotDeferred() async throws {
    try await withStore { _, pool, logger in
      do {
        try await pool.withTransaction(logger: logger) { connection in
          _ = try await connection.query("SELECT 1 / 0", logger: logger)
        }
        Issue.record("Expected division by zero to abort the transaction")
      } catch let error as PostgresTransactionError {
        #expect(error.closureError != nil && error.rollbackError == nil)
        #expect(!PostgresTelemetryRetryPolicy.canDefer(error))
      }
    }
  }

  @Test("blocked rollups abort promptly and roll back earlier bulk chunks before a successful retry")
  func blockedRollupExport() async throws {
    try await withStore { store, pool, logger in
      let prefix = "blocked.\(UUID().uuidString)"
      let now = Date()
      let samples = (0..<260).map { index in
        OperationsTelemetrySignal.metric(.init(
          name: "\(prefix).\(String(format: "%03d", index))", value: Double(index),
          dimensions: ["environment": "prod"], recordedAt: now))
      }
      let blockedName = "\(prefix).259"
      try await store.recordTelemetryBatch([try #require(samples.last)])
      try await pool.withTransaction(logger: logger) { blocker in
        try await blocker.query(
          "UPDATE operations_metric_rollups SET sample_count = sample_count WHERE metric_name = \(blockedName)",
          logger: logger)
        let started = ContinuousClock.now
        do {
          try await store.recordTelemetryBatch(samples)
          Issue.record("Expected the rollup lock to abort the transaction")
        } catch var error as PostgresTransactionError {
          #expect(PostgresTelemetryRetryPolicy.canDefer(error))
          // Replaying additive metrics is safe only when rollback is confirmed.
          error.commitError = CancellationError()
          #expect(!PostgresTelemetryRetryPolicy.canDefer(error))
          error.commitError = nil
          error.rollbackError = CancellationError()
          #expect(!PostgresTelemetryRetryPolicy.canDefer(error))
          error.rollbackError = nil
          error.beginError = CancellationError()
          #expect(!PostgresTelemetryRetryPolicy.canDefer(error))
          error.beginError = nil
          error.closureError = CancellationError()
          #expect(!PostgresTelemetryRetryPolicy.canDefer(error))
        }
        #expect(started.duration(to: .now) < .seconds(3))
        let rows = try await pool.query(
          "SELECT COUNT(*)::bigint FROM operations_metric_rollups WHERE metric_name LIKE \(prefix + "%")",
          logger: logger)
        for try await row in rows { #expect(try row.decode(Int64.self) == 1) }
      }
      // The same batch succeeds after contention clears, with no duplicated earlier chunk.
      try await store.recordTelemetryBatch(samples)
      let rows = try await pool.query(
        """
        SELECT COUNT(*)::bigint, SUM(sample_count)::bigint, SUM(value_sum)::double precision
        FROM operations_metric_rollups WHERE metric_name LIKE \(prefix + "%")
        """, logger: logger)
      for try await row in rows {
        let value = try row.decode((Int64, Int64, Double).self)
        #expect(value.0 == 260 && value.1 == 261 && value.2 == 33_929)
      }
      // Exercise pooled sessions concurrently: local timeout settings must not leak.
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        for _ in 0..<4 {
          tasks.addTask {
            try await pool.withConnection { connection in
              let settings = try await connection.query(
                "SELECT current_setting('statement_timeout'), current_setting('lock_timeout')",
                logger: logger)
              for try await row in settings {
                let value = try row.decode((String, String).self)
                #expect(value.0 == "0" && value.1 == "0")
              }
            }
          }
        }
        try await tasks.waitForAll()
      }
    }
  }

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

  @Test("delayed buffer exports preserve metric totals and event and span identities")
  func delayedMixedBufferBatch() async throws {
    try await withStore { store, pool, logger in
      let suffix = UUID().uuidString.lowercased()
      let at = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
      let clock = ContinuousClock.now
      let buffer = OperationsTelemetryBuffer(store: store, batchDelay: .seconds(1), logger: logger)
      for value in 1...10 {
        #expect(await buffer.enqueue(.metric(.init(
          name: "buffer.\(suffix)", value: Double(value), dimensions: [:], recordedAt: at)), at: clock))
      }
      #expect(await buffer.enqueue(.event(.init(
        id: suffix, service: "test", environment: "prod", instanceId: "test",
        name: "buffer.event", occurredAt: at, traceId: "trace-\(suffix)")), at: clock))
      #expect(await buffer.enqueue(.span(.init(
        id: suffix, environment: "prod", traceId: "trace-\(suffix)", service: "test",
        name: "buffer.span", startedAt: at, durationMs: 12.5, status: "ok", attributes: [:],
        expiresAt: at.addingTimeInterval(86400))), at: clock))
      #expect(await buffer.flushIfReady(at: clock.advanced(by: .milliseconds(999))) == 0)
      #expect(await buffer.flushIfReady(at: clock.advanced(by: .seconds(1))) == 12)
      let metrics = try await pool.query(
        """
        SELECT sample_count, value_sum, value_min, value_max, bucket_start
        FROM operations_metric_rollups WHERE environment = 'prod' AND metric_name = \("buffer." + suffix)
        """, logger: logger)
      var metricCount = 0
      for try await row in metrics {
        let value = try row.decode((Int64, Double, Double, Double, Date).self)
        #expect(value.0 == 10 && value.1 == 55 && value.2 == 1 && value.3 == 10 && value.4 == at)
        metricCount += 1
      }
      #expect(metricCount == 1)
      let events = try await pool.query(
        "SELECT event_name, occurred_at, trace_id FROM operations_events WHERE environment = 'prod' AND id = \(suffix)",
        logger: logger)
      var eventCount = 0
      for try await row in events {
        let value = try row.decode((String, Date, String).self)
        #expect(value.0 == "buffer.event" && value.1 == at && value.2 == "trace-\(suffix)")
        eventCount += 1
      }
      #expect(eventCount == 1)
      let spans = try await pool.query(
        "SELECT name, started_at, duration_ms, trace_id FROM operations_trace_spans WHERE environment = 'prod' AND id = \(suffix)",
        logger: logger)
      var spanCount = 0
      for try await row in spans {
        let value = try row.decode((String, Date, Double, String).self)
        #expect(value.0 == "buffer.span" && value.1 == at && value.2 == 12.5 && value.3 == "trace-\(suffix)")
        spanCount += 1
      }
      #expect(spanCount == 1)
      #expect(await buffer.snapshot().droppedCount == 0)
    }
  }

  @Test("bulk event and span chunks preserve optional IDs, expiry, duplicate identity and environment isolation")
  func bulkEventAndSpanChunks() async throws {
    try await withStore { store, pool, logger in
      let prefix = "bulk.\(UUID().uuidString)"
      let at = Date(timeIntervalSince1970: 1_789_000_000)
      var signals: [OperationsTelemetrySignal] = []
      for index in 0..<260 {
        let id = "\(prefix).\(String(format: "%03d", index))"
        let optional: String? = index % 3 == 0 ? nil : (index % 3 == 1 ? "" : "linked")
        signals.append(.event(.init(
          id: id, service: "test", environment: "prod", instanceId: "instance",
          name: "bulk.event", occurredAt: at, requestId: optional, traceId: optional,
          attributes: ["lane": "test"])))
        signals.append(.span(.init(
          id: id, environment: "prod", traceId: "trace", parentSpanId: optional,
          service: "test", name: "bulk.span", startedAt: at, durationMs: 12.5,
          status: "ok", attributes: ["lane": "test"], expiresAt: at.addingTimeInterval(86400))))
      }
      signals.append(try #require(signals.first))
      signals.append(try #require(signals.dropFirst().first))
      try await store.recordTelemetryBatch(signals)
      // A replay must not rewrite existing event/span identities or extend their retention.
      try await store.recordTelemetryBatch(signals.reversed())
      let events = try await pool.query(
        """
        SELECT id, request_id, trace_id, occurred_at, expires_at, attributes->>'lane'
        FROM operations_events WHERE environment = 'prod' AND id LIKE \(prefix + "%") ORDER BY id
        """, logger: logger)
      var eventCount = 0
      for try await row in events {
        let v = try row.decode((String, String?, String?, Date, Date, String).self)
        let expected: String? = eventCount % 3 == 0 ? nil : (eventCount % 3 == 1 ? "" : "linked")
        #expect(v.1 == expected && v.2 == expected && v.3 == at)
        #expect(v.4 == at.addingTimeInterval(30 * 86400) && v.5 == "test")
        eventCount += 1
      }
      #expect(eventCount == 260)
      let spans = try await pool.query(
        """
        SELECT parent_span_id, started_at, expires_at, duration_ms, attributes->>'lane'
        FROM operations_trace_spans WHERE environment = 'prod' AND id LIKE \(prefix + "%") ORDER BY id
        """, logger: logger)
      var spanCount = 0
      for try await row in spans {
        let v = try row.decode((String?, Date, Date, Double, String).self)
        let expected: String? = spanCount % 3 == 0 ? nil : (spanCount % 3 == 1 ? "" : "linked")
        #expect(v.0 == expected && v.1 == at && v.2 == at.addingTimeInterval(86400))
        #expect(v.3 == 12.5 && v.4 == "test")
        spanCount += 1
      }
      #expect(spanCount == 260)
      let other = PostgresOperationsStore(pool: pool, environment: "dev", logger: logger)
      try await other.recordTelemetryBatch([
        .event(.init(id: prefix + ".000", service: "test", environment: "dev", instanceId: "test",
          name: "isolated", occurredAt: at)),
        .span(.init(id: prefix + ".000", environment: "dev", traceId: "other", service: "test",
          name: "isolated", startedAt: at, durationMs: 1, status: "ok", attributes: [:],
          expiresAt: at.addingTimeInterval(86400))),
      ])
      let counts = try await pool.query(
        """
        SELECT (SELECT COUNT(*) FROM operations_events WHERE id = \(prefix + ".000")),
          (SELECT COUNT(*) FROM operations_trace_spans WHERE id = \(prefix + ".000"))
        """, logger: logger)
      for try await row in counts {
        let v = try row.decode((Int64, Int64).self)
        #expect(v.0 == 2 && v.1 == 2)
      }
    }
  }

  @Test("a blocked last span rolls back earlier event chunks and metrics before a lossless retry")
  func blockedSpanRollsBackMixedBatch() async throws {
    try await withStore { store, pool, logger in
      let prefix = "mixed-blocked.\(UUID().uuidString)"
      let at = Date()
      var signals: [OperationsTelemetrySignal] = [.metric(.init(name: prefix, value: 7, dimensions: [:], recordedAt: at))]
      for index in 0..<260 {
        let id = "\(prefix).\(String(format: "%03d", index))"
        signals.append(.event(.init(id: id, service: "test", environment: "prod", instanceId: "test",
          name: prefix, occurredAt: at)))
        signals.append(.span(.init(id: id, environment: "prod", traceId: prefix, service: "test",
          name: prefix, startedAt: at, durationMs: 1, status: "ok", attributes: [:],
          expiresAt: at.addingTimeInterval(86400))))
      }
      try await store.recordTelemetryBatch([try #require(signals.last)])
      try await pool.withTransaction(logger: logger) { blocker in
        try await blocker.query(
          "UPDATE operations_trace_spans SET status = status WHERE environment = 'prod' AND id = \(prefix + ".259")",
          logger: logger)
        await #expect(throws: (any Error).self) { try await store.recordTelemetryBatch(signals) }
        let counts = try await pool.query(
          """
          SELECT (SELECT COUNT(*) FROM operations_metric_rollups WHERE metric_name = \(prefix)),
            (SELECT COUNT(*) FROM operations_events WHERE event_name = \(prefix)),
            (SELECT COUNT(*) FROM operations_trace_spans WHERE name = \(prefix))
          """, logger: logger)
        for try await row in counts {
          let v = try row.decode((Int64, Int64, Int64).self)
          #expect(v.0 == 0 && v.1 == 0 && v.2 == 1)
        }
      }
      try await store.recordTelemetryBatch(signals)
      let counts = try await pool.query(
        """
        SELECT (SELECT SUM(sample_count)::bigint FROM operations_metric_rollups WHERE metric_name = \(prefix)),
          (SELECT COUNT(*) FROM operations_events WHERE event_name = \(prefix)),
          (SELECT COUNT(*) FROM operations_trace_spans WHERE name = \(prefix))
        """, logger: logger)
      for try await row in counts {
        let v = try row.decode((Int64, Int64, Int64).self)
        #expect(v.0 == 1 && v.1 == 260 && v.2 == 260)
      }
    }
  }

  @Test("concurrent batches with shared event and span identities retain every coalesced sample")
  func concurrentSharedIdentities() async throws {
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
            let event = OperationsTelemetrySignal.event(.init(
              id: prefix, service: "test", environment: "prod", instanceId: "test", name: prefix))
            let span = OperationsTelemetrySignal.span(.init(
              id: prefix, environment: "prod", traceId: prefix, service: "test", name: prefix,
              startedAt: now, durationMs: 1, status: "ok", attributes: [:],
              expiresAt: now.addingTimeInterval(86400)))
            try await store.recordTelemetryBatch(samples + [event, span])
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

  @Test("concurrent rollup writers preserve every sample across chunks", arguments: [false, true])
  func concurrentRollupWriters(includeUniqueIdentities: Bool) async throws {
    try await withStore { _, pool, logger in
      let prefix = "rollup-concurrent.\(UUID().uuidString)"
      let recordedAt = Date()
      let writerCount = 8
      let keyCount = 260
      let gate = TelemetryWriterStartGate(participants: writerCount)
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        for writer in 0..<writerCount {
          tasks.addTask {
            let store = PostgresOperationsStore(pool: pool, environment: "prod", logger: logger)
            let indices = writer.isMultiple(of: 2)
              ? Array(0..<keyCount) : Array((0..<keyCount).reversed())
            var signals = indices.flatMap { index in
              [-2.0, Double(index), 10.0].map { value in
                OperationsTelemetrySignal.metric(.init(
                  name: "\(prefix).\(String(format: "%03d", index))", value: value,
                  dimensions: ["environment": "prod"], recordedAt: recordedAt))
              }
            }
            if includeUniqueIdentities {
              // Shared identities serialize exports before rollups and hide conflicting
              // metric lock orders. Every mixed writer must own different identities.
              let identity = "\(prefix).writer-\(writer)"
              signals.append(.event(.init(
                id: identity, service: "test", environment: "prod", instanceId: identity,
                name: prefix, occurredAt: recordedAt)))
              signals.append(.span(.init(
                id: identity, environment: "prod", traceId: identity, service: "test",
                name: prefix, startedAt: recordedAt, durationMs: 1, status: "ok",
                attributes: [:], expiresAt: recordedAt.addingTimeInterval(86400))))
            }
            await gate.wait()
            // More than 250 coalesced keys forces multiple SQL chunks while all
            // transactions compete for the same rollups in opposite input orders.
            try await store.recordTelemetryBatch(signals)
          }
        }
        try await tasks.waitForAll()
      }
      let rows = try await pool.query(
        """
        SELECT metric_name, sample_count, value_sum, value_min, value_max
        FROM operations_metric_rollups
        WHERE environment = 'prod' AND metric_name LIKE \(prefix + "%")
        ORDER BY metric_name
        """, logger: logger)
      var count = 0
      for try await row in rows {
        let value = try row.decode((String, Int64, Double, Double, Double).self)
        #expect(value.0 == "\(prefix).\(String(format: "%03d", count))")
        #expect(value.1 == Int64(writerCount * 3))
        #expect(value.2 == Double(writerCount * (count + 8)))
        #expect(value.3 == -2 && value.4 == max(10, Double(count)))
        count += 1
      }
      #expect(count == keyCount)
      let identities = try await pool.query(
        """
        SELECT (SELECT COUNT(*) FROM operations_events
          WHERE environment = 'prod' AND event_name = \(prefix)),
          (SELECT COUNT(*) FROM operations_trace_spans
          WHERE environment = 'prod' AND name = \(prefix))
        """, logger: logger)
      for try await row in identities {
        let value = try row.decode((Int64, Int64).self)
        let expected = includeUniqueIdentities ? Int64(writerCount) : 0
        #expect(value.0 == expected && value.1 == expected)
      }
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

private actor TelemetryWriterStartGate {
  private let participants: Int
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(participants: Int) {
    self.participants = participants
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      waiting.append(continuation)
      if waiting.count == participants {
        let ready = waiting
        waiting.removeAll()
        for participant in ready { participant.resume() }
      }
    }
  }
}
