import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("ordered signal mutation preserves replay identity, retractions and newer source facts")
  func orderedSignalReplayAndRetraction() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let first = try await fixture.item("first")
      let second = try await fixture.item("second")
      let source = "at://did:example:ordered/app.bsky.feed.like/\(fixture.prefix)"
      let event = "\(fixture.prefix):1"
      try await fixture.insertOrderedSignal(first, source: source, event: event, occurredAt: fixture.now)
      let initial = try await fixture.orderedSignalFacts()
      #expect(initial.count == 1)
      let object = try #require(JSONSerialization.jsonObject(with: Data(initial[0].utf8)) as? [String: Any])
      #expect(object["event_key"] as? String == event)
      #expect(object["transport_event_key"] as? String == "transport:" + event)
      #expect(object["source_uri"] as? String == source)
      #expect(object["source_action"] as? String == "like")
      try await fixture.insertOrderedSignal(first, source: source, event: event, occurredAt: fixture.now)
      #expect(try await fixture.orderedSignalFacts() == initial)
      // Same transport identity from another source must not add another fact.
      try await fixture.insertOrderedSignal(second, source: source + "-duplicate", event: event, occurredAt: fixture.now)
      #expect(try await fixture.orderedSignalFacts() == initial)
      let changed = fixture.now.addingTimeInterval(2)
      try await fixture.insertOrderedSignal(second, source: source, event: event + "-new", occurredAt: changed)
      let replacement = try await fixture.orderedSignalFacts()
      #expect(replacement.count == 1)
      #expect(replacement[0].contains(second))
      let hints = try await fixture.orderedSignalHints()
      #expect(hints.contains { $0.contains(first) })
      #expect(hints.contains { $0.contains(second) })
      try await fixture.insertOrderedSignal(first, source: source, event: event + "-old", occurredAt: fixture.now)
      #expect(try await fixture.orderedSignalFacts() == replacement)
      #expect(try await fixture.orderedSignalHints() == hints)
      try await fixture.store.refresh(asOf: changed)
      #expect(try await fixture.snapshot(first) == nil)
      #expect(try await fixture.counts(second)["signals_7d"] == 1)
      try await fixture.pool.query("DELETE FROM wire_signal_events WHERE source_uri = \(source)", logger: fixture.logger)
      try await fixture.store.refresh(asOf: changed)
      #expect(try await fixture.snapshot(second) == nil)
    }
  }

  @Test("ordered signal mutation rolls back source changes and dirty revisions with its caller")
  func orderedSignalCallerRollback() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let first = try await fixture.item("before")
      let second = try await fixture.item("rolled-back")
      let source = fixture.prefix + "-source"
      try await fixture.insertOrderedSignal(first, source: source, event: source, occurredAt: fixture.now)
      let facts = try await fixture.orderedSignalFacts()
      let hints = try await fixture.orderedSignalHints()
      await #expect(throws: (any Error).self) {
        try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          try await fixture.insertOrderedSignal(second, source: source, event: source + "-new", occurredAt: fixture.now.addingTimeInterval(1), on: connection)
          try await connection.query("SELECT 1 / 0", logger: fixture.logger)
        }
      }
      #expect(try await fixture.orderedSignalFacts() == facts)
      #expect(try await fixture.orderedSignalHints() == hints)
    }
  }

  @Test("ordered signal mutation keeps later dirty revisions after concurrent refresh acknowledgment")
  func orderedSignalConcurrentAcknowledgment() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("ack")
      let source = fixture.prefix + "-source"
      try await fixture.insertOrderedSignal(key, source: source, event: source, occurredAt: fixture.now)
      try await fixture.store.refresh(asOf: fixture.now)
      try await fixture.insertOrderedSignal(key, source: source, event: source + "-second", occurredAt: fixture.now)
      let claimed = try await fixture.orderedSignalHints()
      try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
        try await fixture.store.configureRefreshSnapshot(connection: connection)
        #expect(try await fixture.store.prepareIncrementalRefresh(connection: connection, asOf: fixture.now))
        try await fixture.insertOrderedSignal(key, source: source, event: source + "-third", occurredAt: fixture.now)
        try await connection.query(
          "CREATE TEMP TABLE wire_signal_rollups_next ON COMMIT DROP AS SELECT rollup.*, now() + interval '1 hour' AS next_due_at FROM wire_signal_rollups rollup",
          logger: fixture.logger)
        try await fixture.store.finishIncrementalRefresh(connection: connection, asOf: fixture.now)
      }
      let remaining = try await fixture.orderedSignalHints()
      #expect(!remaining.isEmpty)
      #expect(remaining != claimed)
      try await fixture.store.refresh(asOf: fixture.now)
      #expect(try await fixture.counts(key)["signals_7d"] == 1)
      #expect(try await fixture.orderedSignalHints().isEmpty)
    }
  }

  @Test("ordered signal mutation uses the UTC partition in a non-UTC session")
  func orderedSignalUTCPartition() async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      let key = try await fixture.item("utc")
      let source = fixture.prefix + "-utc"
      let occurredAt = try #require(ISO8601DateFormatter().date(from: "2098-06-03T23:59:59Z"))
      try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
        try await connection.query("SET LOCAL TIME ZONE 'Pacific/Kiritimati'", logger: fixture.logger)
        try await fixture.insertOrderedSignal(key, source: source, event: source, occurredAt: occurredAt, on: connection)
        let rows = try await connection.query(
          "SELECT tableoid = 'public.wire_signal_events_20980603'::regclass, occurred_at FROM wire_signal_events WHERE source_uri = \(source)", logger: fixture.logger)
        var found = false
        for try await row in rows {
          let (utcPartition, actualTime) = try row.decode((Bool, Date).self)
          #expect(utcPartition)
          #expect(actualTime == occurredAt)
          found = true
        }
        #expect(found)
      }
    }
  }

  @Test("an insert error inside the ordered function restores deleted facts and hints")
  func orderedSignalInsertFailureRollback() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true) { fixture in
      let key = try await fixture.item("constraint")
      let source = fixture.prefix + "-source"
      try await fixture.insertOrderedSignal(key, source: source, event: source, occurredAt: fixture.now)
      let facts = try await fixture.orderedSignalFacts()
      let hints = try await fixture.orderedSignalHints()
      do {
        try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
          // NULL violates canonical_key only after the old source DELETE runs.
          _ = try await connection.query(
            """
            SELECT public.wire_insert_signal(
              \(source + "-invalid"), \(source + "-invalid"), NULL, 'like', 'actor',
              \(source), 'app.bsky.feed.like', \(fixture.now), \(fixture.now.addingTimeInterval(86_400)))
            """, logger: fixture.logger).collect()
        }
        Issue.record("the function must propagate its insert constraint failure")
      } catch let error as PostgresTransactionError {
        #expect((error.closureError as? PSQLError)?.serverInfo?[.sqlState] == "23502")
      }
      #expect(try await fixture.orderedSignalFacts() == facts)
      #expect(try await fixture.orderedSignalHints() == hints)
    }
  }

  @Test("ordered signal timeout propagates without changing facts or revisions")
  func orderedSignalTimeoutRollback() async throws {
    try await WireRollupIntegrationFixture.run(incremental: true, maximumConnections: 3) { fixture in
      let key = try await fixture.item("timeout")
      let source = fixture.prefix + "-source"
      try await fixture.insertOrderedSignal(key, source: source, event: source, occurredAt: fixture.now)
      let facts = try await fixture.orderedSignalFacts()
      let hints = try await fixture.orderedSignalHints()
      try await fixture.pool.withTransaction(logger: fixture.logger) { holder in
        _ = try await holder.query(
          "SELECT pg_advisory_xact_lock(hashtextextended(\(source), 0))", logger: fixture.logger).collect()
        do {
          try await fixture.pool.withTransaction(logger: fixture.logger) { waiter in
            try await waiter.query("SET LOCAL statement_timeout = '100ms'", logger: fixture.logger)
            try await fixture.insertOrderedSignal(key, source: source, event: source + "-timeout", occurredAt: fixture.now, on: waiter)
          }
          Issue.record("the function call must fail within the existing statement timeout")
        } catch let error as PostgresTransactionError {
          #expect((error.closureError as? PSQLError)?.serverInfo?[.sqlState] == "57014")
        }
      }
      #expect(try await fixture.orderedSignalFacts() == facts)
      #expect(try await fixture.orderedSignalHints() == hints)
      // A normal transaction can retry after rollback; no source or pool reset.
      try await fixture.insertOrderedSignal(key, source: source, event: source + "-retry", occurredAt: fixture.now)
      #expect(try await fixture.orderedSignalFacts().count == 1)
    }
  }

  @Test("the worker retries a failed ordered call instead of acknowledging its SELECT early")
  func orderedSignalWorkerAcknowledgmentWaitsForResult() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    try await WireRollupIntegrationFixture.run { fixture in
      let key = try await fixture.item("worker-timeout")
      let environment = fixture.prefix
      let did = "did:example:\(fixture.prefix)"
      let source = "at://\(did)/app.bsky.feed.like/signal"
      let subject = "at://\(did)/app.bsky.feed.post/subject"
      try await fixture.pool.query(
        "INSERT INTO wire_item_aliases(alias_key, canonical_key, alias_type, expires_at) VALUES (\(subject), \(key), 'at_uri', \(fixture.now.addingTimeInterval(86_400)))", logger: fixture.logger)
      let payload = "{\"commit\":{\"record\":{\"subject\":{\"uri\":\"\(subject)\",\"cid\":\"bafytest\"}}}}"
      try await fixture.pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
           collection, operation, record_key, payload, event_time, next_attempt_at)
        VALUES (\(environment), 'ordered-call-test', 1, 'test', 'jetstream_v2_seq', 'commit', \(did),
          'app.bsky.feed.like', 'create', 'signal', \(payload)::jsonb, \(fixture.now), \(fixture.now))
        """, logger: fixture.logger)
      var configuration = try PostgresWireConfig.make(from: url, logger: fixture.logger)
      configuration.options.additionalStartupParameters.append(("options", "-c statement_timeout=100ms"))
      let workerPool = PostgresClient(configuration: configuration, backgroundLogger: fixture.logger)
      let run = Task { await workerPool.run() }
      defer { run.cancel() }
      let processor = try PostgresWireInboxProcessor(
        pool: workerPool, logger: fixture.logger, actorSecret: String(repeating: "s", count: 32),
        sourceScope: .init(environment: environment, sourceGenerations: ["ordered-call-test"]))
      try await fixture.pool.withTransaction(logger: fixture.logger) { holder in
        _ = try await holder.query(
          "SELECT pg_advisory_xact_lock(hashtextextended(\(source), 0))", logger: fixture.logger).collect()
        let metrics = try await processor.processWithMetrics(asOf: fixture.now)
        #expect(metrics.attemptedEventCount == 1)
        #expect(metrics.appliedEventCount == 0)
      }
      let rows = try await fixture.pool.query(
        "SELECT status, attempt_count FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: fixture.logger)
      for try await row in rows {
        let (status, attempts) = try row.decode((String, Int).self)
        #expect(status == "retry")
        #expect(attempts == 1)
      }
      #expect(try await fixture.orderedSignalFacts().isEmpty)
      #expect(try await processor.process(asOf: fixture.now.addingTimeInterval(61)) == 1)
      #expect(try await fixture.orderedSignalFacts().count == 1)
      try await fixture.pool.query("DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: fixture.logger)
      try await fixture.pool.query("DELETE FROM wire_ingestion_admission WHERE environment = \(environment)", logger: fixture.logger)
      try await fixture.pool.query(
        "DELETE FROM wire_active_actors WHERE actor_key_hash = \(try processor.actorHasher.hash(did))", logger: fixture.logger)
    }
  }

  @Test("ordered signal source-lock waiter preserves isolation after newer commit", .timeLimit(.minutes(1)), arguments: [false, true])
  func orderedSignalSourceLockSnapshot(repeatableRead: Bool) async throws {
    try await WireRollupIntegrationFixture.run(maximumConnections: 3) { fixture in
      let oldKey = try await fixture.item("old")
      let newKey = try await fixture.item("new")
      let source = fixture.prefix + "-source"
      try await fixture.insertOrderedSignal(oldKey, source: source, event: source, occurredAt: fixture.now.addingTimeInterval(-1))
      let ready = AsyncStream<Void>.makeStream()
      let waitingPID = AsyncStream<Int32>.makeStream()
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
          defer { ready.continuation.finish() }
          try await fixture.pool.withTransaction(logger: fixture.logger) { holder in
            try await fixture.insertOrderedSignal(newKey, source: source, event: source + "-new", occurredAt: fixture.now.addingTimeInterval(2), on: holder)
            ready.continuation.yield()
            var pids = waitingPID.stream.makeAsyncIterator()
            let pid = try #require(await pids.next())
            var observed = false
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
              let rows = try await holder.query(
                "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid = \(pid) AND locktype = 'advisory' AND NOT granted)", logger: fixture.logger)
              for try await row in rows { observed = try row.decode(Bool.self) }
              if observed { break }
              try await Task.sleep(for: .milliseconds(5))
            }
            #expect(observed, "waiter must begin its call before the winning transaction commits")
          }
        }
        tasks.addTask {
          defer { waitingPID.continuation.finish() }
          var iterator = ready.stream.makeAsyncIterator()
          _ = try #require(await iterator.next())
          do {
            try await fixture.pool.withTransaction(logger: fixture.logger) { waiter in
              if repeatableRead {
                try await waiter.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", logger: fixture.logger)
              }
              try await waiter.query("SET LOCAL statement_timeout = '8s'", logger: fixture.logger)
              let rows = try await waiter.query(
                "SELECT pg_backend_pid(), current_setting('transaction_isolation'), canonical_key FROM wire_signal_events WHERE source_uri = \(source)", logger: fixture.logger)
              for try await row in rows {
                let (pid, isolation, key) = try row.decode((Int32, String, String).self)
                #expect(isolation == (repeatableRead ? "repeatable read" : "read committed"))
                #expect(key == oldKey)
                waitingPID.continuation.yield(pid)
              }
              try await fixture.insertOrderedSignal(oldKey, source: source, event: source + "-stale", occurredAt: fixture.now, on: waiter)
            }
            #expect(!repeatableRead, "repeatable-read preserves its earlier snapshot and must retry the transaction")
          } catch let error as PostgresTransactionError {
            let postgres = error.closureError as? PSQLError
            #expect(repeatableRead)
            #expect(postgres?.serverInfo?[.sqlState] == "40001")
          }
        }
        try await tasks.waitForAll()
      }
      let facts = try await fixture.orderedSignalFacts()
      #expect(facts.count == 1)
      #expect(facts[0].contains(source + "-new"))
      #expect(facts[0].contains(newKey))
    }
  }
}
