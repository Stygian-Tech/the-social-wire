import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorker

@Suite(
  "The Wire PostgreSQL integration",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
    "Set WIRE_TEST_DATABASE_URL to an explicitly disposable migrated PostgreSQL database."
  )
)
struct WirePostgresIntegrationTests {
  @Test("a staged payload-normalization fallback is dead-lettered")
  func payloadNormalizationFallbackDeadLetters() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-normalization-fallback-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-normalization-\(UUID().uuidString.lowercased())"
    let generation = "wire-normalization-v1"
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:normalization-fallback',
         '{"$wireIngestionError":{"code":"payload_normalization_failed","version":1,"originalBytes":42}}'::jsonb,
         \(now))
      """,
      logger: logger
    )
    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32)
    )
    #expect(try await processor.process(asOf: now.addingTimeInterval(1)) == 1)

    let rows = try await pool.query(
      """
      SELECT status, failure_reason, dead_lettered_at IS NOT NULL
      FROM wire_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(generation) AND seq = 1
      """,
      logger: logger
    )
    for try await row in rows {
      let result = try row.decode((String, String?, Bool).self)
      #expect(result.0 == "dead_letter")
      #expect(result.1 == "malformed_event")
      #expect(result.2)
    }
    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
  }

  @Test("continuous runtime drains successive bounded PostgreSQL batches")
  func continuousPostgresDrain() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-continuous-drain-postgres.integration")
    let configuration = try PostgresWireConfig.make(
      from: url, maximumConnections: 8, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-drain-\(UUID().uuidString.lowercased())"
    let generation = "wire-drain-v1"
    let repoPrefix = "did:example:drain-\(UUID().uuidString.lowercased())-"
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time)
      SELECT \(environment), \(generation), sequence, 'test', 'jetstream_v2_seq',
             'identity', \(repoPrefix) || sequence::text, '{}'::jsonb, \(now)
      FROM generate_series(1, 37) AS rows(sequence)
      """,
      logger: logger
    )
    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 10,
      maximumConcurrentEvents: 8
    )
    let sleeper = IntegrationDrainSleeper()
    try await WireInboxDrainRuntime.run(
      processor: processor,
      state: WireWorkerHealthState(),
      logger: logger,
      configuration: .init(idleMilliseconds: 250),
      sleeper: sleeper,
      iterationLimit: 5
    )

    let rows = try await pool.query(
      """
      SELECT COUNT(*) FILTER (WHERE status = 'applied')::bigint,
             COUNT(*) FILTER (WHERE status IN ('pending','leased','retry'))::bigint
      FROM wire_ingestion_inbox
      WHERE environment = \(environment)
      """,
      logger: logger
    )
    for try await row in rows {
      let counts = try row.decode((Int64, Int64).self)
      #expect(counts.0 == 37)
      #expect(counts.1 == 0)
    }
    #expect(await sleeper.delays == [250])
    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
  }

  @Test("claiming preserves repository FIFO while batching different repositories")
  func repositoryFIFOAcrossConcurrentClaim() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-repository-fifo-postgres.integration")
    let configuration = try PostgresWireConfig.make(
      from: url, maximumConnections: 8, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-fifo-\(UUID().uuidString.lowercased())"
    let generation = "wire-fifo-v1"
    let sharedRepo = "did:example:fifo-shared-\(UUID().uuidString.lowercased())"
    let otherRepo = "did:example:fifo-other-\(UUID().uuidString.lowercased())"
    let now = Date()
    for (sequence, repoDID) in [(1, sharedRepo), (2, sharedRepo), (3, otherRepo)] {
      try await pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind,
           repo_did, payload, event_time)
        VALUES
          (\(environment), \(generation), \(sequence), 'test', 'jetstream_v2_seq',
           'identity', \(repoDID), '{}'::jsonb, \(now))
        """,
        logger: logger
      )
    }

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 10,
      maximumConcurrentEvents: 8
    )
    let firstProcessAt = Date()
    #expect(try await processor.process(asOf: firstProcessAt) == 2)

    let firstClaimRows = try await pool.query(
      """
      SELECT seq, status
      FROM wire_ingestion_inbox
      WHERE environment = \(environment)
      ORDER BY seq
      """,
      logger: logger
    )
    var firstClaimStatuses: [(Int64, String)] = []
    for try await row in firstClaimRows {
      firstClaimStatuses.append(try row.decode((Int64, String).self))
    }
    #expect(firstClaimStatuses.map(\.0) == [1, 2, 3])
    #expect(firstClaimStatuses.map(\.1) == ["applied", "pending", "applied"])

    #expect(try await processor.process(asOf: firstProcessAt.addingTimeInterval(1)) == 1)
    let finalRows = try await pool.query(
      """
      SELECT COUNT(*) FILTER (WHERE status = 'applied')::bigint,
             COUNT(*) FILTER (WHERE status IN ('pending','leased','retry'))::bigint
      FROM wire_ingestion_inbox
      WHERE environment = \(environment)
      """,
      logger: logger
    )
    for try await row in finalRows {
      let counts = try row.decode((Int64, Int64).self)
      #expect(counts.0 == 3)
      #expect(counts.1 == 0)
    }
    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
  }

  @Test("ready pending work is not starved by an older retry while repository FIFO remains intact")
  func pendingWorkIsNotStarvedByRetry() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-retry-fairness-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-fairness-\(UUID().uuidString.lowercased())"
    let generation = "wire-fairness-v1"
    let blockedRepo = "did:plc:blocked\(UUID().uuidString.lowercased())"
    let readyRepo = "did:plc:ready\(UUID().uuidString.lowercased())"
    let now = Date()
    let unresolvedPayload = """
      {"commit":{"record":{"$type":"site.standard.document","site":"at://\(blockedRepo)/site.standard.publication/main","path":"story"}}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, record_key, payload, event_time, status, next_attempt_at)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'commit', \(blockedRepo),
         'site.standard.document', 'create', 'first', \(unresolvedPayload)::jsonb, \(now),
         'retry', \(now.addingTimeInterval(-10))),
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'identity', \(blockedRepo),
         NULL, NULL, NULL, '{}'::jsonb, \(now), 'pending', \(now.addingTimeInterval(-3_600))),
        (\(environment), \(generation), 3, 'test', 'jetstream_v2_seq', 'identity', \(readyRepo),
         NULL, NULL, NULL, '{}'::jsonb, \(now), 'pending', \(now.addingTimeInterval(-3_600)))
      """,
      logger: logger
    )

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 1,
      maximumConcurrentEvents: 1
    )
    #expect(try await processor.process(asOf: now) == 1)

    let rows = try await pool.query(
      """
      SELECT seq, status FROM wire_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(generation)
      ORDER BY seq
      """,
      logger: logger
    )
    var statuses: [(Int64, String)] = []
    for try await row in rows { statuses.append(try row.decode((Int64, String).self)) }
    #expect(statuses.map(\.0) == [1, 2, 3])
    #expect(statuses.map(\.1) == ["retry", "pending", "applied"])

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
  }

  @Test("pending/retry and expired-lease branches preserve global eligibility order")
  func claimBranchesPreserveGlobalEligibilityOrder() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-claim-branches-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-claim-branches-\(UUID().uuidString.lowercased())"
    let generation = "wire-claim-branches-v1"
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time, status, next_attempt_at, lease_owner,
         lease_token, lease_expires_at)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:branch-pending', '{}'::jsonb, \(now), 'pending',
         \(now.addingTimeInterval(-120)), NULL, NULL, NULL),
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:branch-retry', '{}'::jsonb, \(now), 'retry',
         \(now.addingTimeInterval(-60)), NULL, NULL, NULL),
        (\(environment), \(generation), 3, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:branch-expired', '{}'::jsonb, \(now), 'leased', \(now),
         'old-worker', 'expired-token', \(now.addingTimeInterval(-90))),
        (\(environment), \(generation), 4, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:branch-live', '{}'::jsonb, \(now), 'leased', \(now),
         'live-worker', 'live-token', \(now.addingTimeInterval(60))),
        (\(environment), \(generation), 5, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:branch-pending', '{}'::jsonb, \(now), 'pending',
         \(now.addingTimeInterval(-300)), NULL, NULL, NULL)
      """,
      logger: logger
    )

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 2,
      maximumConcurrentEvents: 2
    )
    #expect(try await processor.process(asOf: now) == 2)

    let rows = try await pool.query(
      """
      SELECT seq, status
      FROM wire_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(generation)
      ORDER BY seq
      """,
      logger: logger
    )
    var states: [(Int64, String)] = []
    for try await row in rows { states.append(try row.decode((Int64, String).self)) }
    #expect(states.map(\.0) == [1, 2, 3, 4, 5])
    #expect(states.map(\.1) == ["applied", "retry", "applied", "leased", "pending"])

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
  }

  @Test("expired leases are reclaimed while live leases remain untouched")
  func expiredLeaseRecovery() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-expired-lease-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-expired-lease-\(UUID().uuidString.lowercased())"
    let generation = "wire-expired-lease-v1"
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time, status, lease_owner, lease_token,
         lease_expires_at, next_attempt_at)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:expired-lease', '{}'::jsonb, \(now), 'leased', 'old-worker',
         'expired-token', \(now.addingTimeInterval(-60)), \(now.addingTimeInterval(3_600))),
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:live-lease', '{}'::jsonb, \(now), 'leased', 'live-worker',
         'live-token', \(now.addingTimeInterval(60)), \(now.addingTimeInterval(-3_600)))
      """,
      logger: logger
    )

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 10,
      maximumConcurrentEvents: 2
    )
    #expect(try await processor.process(asOf: now) == 1)

    let rows = try await pool.query(
      """
      SELECT seq, status, lease_token
      FROM wire_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(generation)
      ORDER BY seq
      """,
      logger: logger
    )
    var states: [(Int64, String, String?)] = []
    for try await row in rows {
      states.append(try row.decode((Int64, String, String?).self))
    }
    #expect(states.map(\.0) == [1, 2])
    #expect(states.map(\.1) == ["applied", "leased"])
    #expect(states[1].2 == "live-token")

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
  }

  @Test("overlapping source generations count one stable transport signal")
  func overlappingGenerationsDeduplicateSignals() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-generation-overlap-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-overlap-\(UUID().uuidString.lowercased())"
    let repoDID = "did:plc:overlap\(UUID().uuidString.lowercased())"
    let recordKey = "same-event"
    let sourceURI = "at://\(repoDID)/site.standard.document/\(recordKey)"
    let articleURL = "https://overlap.example/story"
    let eventTime = Date()
    let payload = """
      {"commit":{"record":{"$type":"site.standard.document","url":"\(articleURL)","title":"Overlap"}}}
      """
    for generation in ["wire-overlap-v1", "wire-overlap-v2"] {
      try await pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
           collection, operation, record_key, payload, event_time)
        VALUES
          (\(environment), \(generation), 42, 'jetstream.example', 'jetstream_v2_seq',
           'commit', \(repoDID), 'site.standard.document', 'create', \(recordKey),
           \(payload)::jsonb, \(eventTime))
        """,
        logger: logger
      )
    }

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 10,
      maximumConcurrentEvents: 1
    )
    #expect(try await processor.process(asOf: eventTime.addingTimeInterval(1)) == 2)
    let staleDeletePayload = """
      {"commit":{"operation":"delete","collection":"site.standard.document","rkey":"\(recordKey)"}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, record_key, payload, event_time)
      VALUES
        (\(environment), 'wire-overlap-v3', 41, 'jetstream.example', 'jetstream_v2_seq',
         'commit', \(repoDID), 'site.standard.document', 'delete', \(recordKey),
         \(staleDeletePayload)::jsonb, \(eventTime.addingTimeInterval(-60)))
      """,
      logger: logger
    )
    #expect(try await processor.process(asOf: eventTime.addingTimeInterval(2)) == 1)

    let updatePayload = """
      {"commit":{"record":{"$type":"site.standard.document","url":"\(articleURL)","title":"Overlap Updated"}}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, record_key, payload, event_time)
      VALUES
        (\(environment), 'wire-overlap-v3', 43, 'jetstream.example', 'jetstream_v2_seq',
         'commit', \(repoDID), 'site.standard.document', 'update', \(recordKey),
         \(updatePayload)::jsonb, \(eventTime.addingTimeInterval(60)))
      """,
      logger: logger
    )
    #expect(try await processor.process(asOf: eventTime.addingTimeInterval(61)) == 1)
    try await processor.maintain(asOf: eventTime.addingTimeInterval(61))

    let signalRows = try await pool.query(
      """
      SELECT COUNT(*)::bigint, COUNT(DISTINCT transport_event_key)::bigint,
             MAX(occurred_at)
      FROM wire_signal_events WHERE source_uri = \(sourceURI)
      """,
      logger: logger
    )
    for try await row in signalRows {
      let counts = try row.decode((Int64, Int64, Date?).self)
      #expect(counts.0 == 1)
      #expect(counts.1 == 1)
      #expect(
        abs(try #require(counts.2).timeIntervalSince(eventTime.addingTimeInterval(60))) < 0.001)
    }
    let canonical = try #require(WireCanonicalizer.canonicalize(articleURL))
    let rollupRows = try await pool.query(
      "SELECT signals_7d FROM wire_signal_rollups WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
    for try await row in rollupRows { #expect(try row.decode(Int.self) == 1) }

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
  }

  @Test("publication metadata resolves a Standard Site document and delete removes the projection")
  func standardSitePublicationLifecycle() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-standard-site-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-standard-site-\(UUID().uuidString.lowercased())"
    let generation = "wire-standard-site-v1"
    let repoDID = "did:plc:standardsite\(UUID().uuidString.lowercased())"
    let publicationURI = "at://\(repoDID)/site.standard.publication/main"
    let documentURI = "at://\(repoDID)/site.standard.document/story"
    let now = Date()
    let publicationPayload = """
      {"commit":{"record":{"$type":"site.standard.publication","name":"Fixture Publication","url":"https://standard.example/"}}}
      """
    let documentPayload = """
      {"commit":{"record":{"$type":"site.standard.document","site":"\(publicationURI)","path":"/stories/example","title":"Fixture Story","textContent":"Fixture body"}}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'commit', \(repoDID),
         'site.standard.publication', 'create', 'main', \(publicationPayload)::jsonb, \(now)),
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'commit', \(repoDID),
         'site.standard.document', 'create', 'story', \(documentPayload)::jsonb, \(now))
      """,
      logger: logger
    )

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32)
    )
    #expect(try await processor.process(asOf: now.addingTimeInterval(1)) == 1)
    #expect(try await processor.process(asOf: now.addingTimeInterval(2)) == 1)

    let publicationRows = try await pool.query(
      "SELECT site_url, name FROM wire_publications WHERE publication_uri = \(publicationURI)",
      logger: logger
    )
    for try await row in publicationRows {
      #expect(
        try row.decode((String, String).self) == ("https://standard.example", "Fixture Publication")
      )
    }
    let canonical = try #require(
      WireCanonicalizer.canonicalize("https://standard.example/stories/example"))
    let itemRows = try await pool.query(
      """
      SELECT representative_uri, publication_id, source_name, summary
      FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)
      """,
      logger: logger
    )
    for try await row in itemRows {
      let item = try row.decode((String?, String?, String, String?).self)
      #expect(item.0 == documentURI)
      #expect(item.1 == publicationURI)
      #expect(item.2 == "Fixture Publication")
      #expect(item.3 == "Fixture body")
    }

    let deletePayload = """
      {"commit":{"operation":"delete","collection":"site.standard.publication","rkey":"main"}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 3, 'test', 'jetstream_v2_seq', 'commit', \(repoDID),
         'site.standard.publication', 'delete', 'main', \(deletePayload)::jsonb, \(now))
      """,
      logger: logger
    )
    #expect(try await processor.process(asOf: now.addingTimeInterval(3)) == 1)
    let deletedRows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM wire_publications WHERE publication_uri = \(publicationURI)",
      logger: logger
    )
    for try await row in deletedRows { #expect(try row.decode(Int64.self) == 0) }

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
  }

  @Test("a partial label refresh retains labels for unqueried candidates")
  func partialLabelRefreshScope() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-label-snapshot-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let namespace = UUID().uuidString.lowercased()
    let queriedKey = "url:\(namespace)-queried"
    let unqueriedKey = "url:\(namespace)-unqueried"
    let sourceDID = "did:example:labeler:\(namespace)"
    let labelSource = "\(sourceDID)|subject-hash|spam"
    let now = Date()
    for key in [queriedKey, unqueriedKey] {
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title,
           first_seen_at, last_seen_at, expires_at)
        VALUES
          (\(key), \("https://example.com/\(key)"), 'example.com', 'Example', 'Story',
           \(now), \(now), \(now.addingTimeInterval(86_400)))
        """,
        logger: logger
      )
      try await pool.query(
        """
        INSERT INTO wire_labels
          (canonical_key, label_key, label_value, source, applied_at, expires_at)
        VALUES
          (\(key), 'moderation', 'spam', \(labelSource), \(now),
           \(now.addingTimeInterval(86_400)))
        """,
        logger: logger
      )
    }
    let labeler = try #require(
      WireLabelerEndpoint.parse("\(sourceDID)|https://labels.example").first
    )
    let store = PostgresWireBaselineLabelStore(pool: pool, logger: logger)
    try await store.replaceSnapshot(
      labels: [],
      labelers: [labeler],
      refreshedCanonicalKeys: [queriedKey],
      targetCount: 1,
      refreshedAt: now
    )

    let rows = try await pool.query(
      """
      SELECT canonical_key FROM wire_labels
      WHERE source = \(labelSource)
      ORDER BY canonical_key
      """,
      logger: logger
    )
    var remaining: [String] = []
    for try await row in rows { remaining.append(try row.decode(String.self)) }
    #expect(remaining == [unqueriedKey])

    try await pool.query(
      "DELETE FROM wire_label_refresh_state WHERE source_did = \(sourceDID)",
      logger: logger
    )
    for key in [queriedKey, unqueriedKey] {
      try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    }
  }

  @Test("applies an article, builds exact rollups, and retracts its signal")
  func articleLifecycle() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-test-\(UUID().uuidString.lowercased())"
    let generation = "wire-test-v1"
    let did = "did:plc:wiretest"
    let recordKey = UUID().uuidString.lowercased()
    let articleURL = "https://example.com/story?utm_source=test&id=\(recordKey)"
    let createPayload = """
      {"did":"\(did)","time_us":1,"kind":"commit","commit":{"operation":"create","collection":"site.standard.document","rkey":"\(recordKey)","rev":"one","record":{"$type":"site.standard.document","url":"\(articleURL)","title":"The Wire Integration Story","createdAt":"2026-08-20T12:00:00Z"}}}
      """
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, repo_rev, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'commit', \(did),
         'site.standard.document', 'create', 'one', \(recordKey), \(createPayload)::jsonb, \(now))
      """,
      logger: logger
    )
    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32)
    )
    let createProcessAt = Date()
    let createdCount: Int
    do {
      createdCount = try await processor.process(asOf: createProcessAt)
    } catch {
      Issue.record("Create processing failed: \(String(reflecting: error))")
      return
    }
    #expect(createdCount == 1)
    try await processor.maintain(asOf: createProcessAt)

    let canonical = WireCanonicalizer.canonicalize(articleURL)!
    let itemRows = try await pool.query(
      "SELECT title FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
    var title: String?
    for try await row in itemRows { title = try row.decode(String.self) }
    #expect(title == "The Wire Integration Story")
    let rollupRows = try await pool.query(
      "SELECT shares_24h, signals_7d FROM wire_signal_rollups WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
    var rollup: (Int, Int)?
    for try await row in rollupRows { rollup = try row.decode((Int, Int).self) }
    #expect(rollup?.0 == 1)
    #expect(rollup?.1 == 1)

    let deletePayload = """
      {"did":"\(did)","time_us":2,"kind":"commit","commit":{"operation":"delete","collection":"site.standard.document","rkey":"\(recordKey)","rev":"two"}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, repo_rev, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'commit', \(did),
         'site.standard.document', 'delete', 'two', \(recordKey), \(deletePayload)::jsonb, \(now))
      """,
      logger: logger
    )
    let deleteProcessAt = Date()
    let deletedCount: Int
    do {
      deletedCount = try await processor.process(asOf: deleteProcessAt)
    } catch {
      Issue.record("Delete processing failed: \(String(reflecting: error))")
      return
    }
    #expect(deletedCount == 1)
    let signalRows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
    for try await row in signalRows { #expect(try row.decode(Int64.self) == 0) }

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)", logger: logger)
    let actorHash = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8)).hash(
      did)
    try await pool.query(
      "DELETE FROM wire_active_actors WHERE actor_key_hash = \(actorHash)", logger: logger)
  }
}

private actor IntegrationDrainSleeper: WireInboxDrainSleeping {
  private(set) var delays: [Int] = []
  func sleep(milliseconds: Int) { delays.append(milliseconds) }
}
