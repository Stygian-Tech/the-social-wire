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
  @Test("source-scoped drain never applies or cleans historical generations")
  func sourceScopedDrainIsolation() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-source-scoped-drain-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let suffix = UUID().uuidString.lowercased()
    let environment = "wire-source-scope-\(suffix)"
    let historyGeneration = "wire-global-v3-prod-live-v1"
    let freshGeneration = "wire-global-v4-prod-live-tail-v1"
    let missingSubject = "at://did:example:story/app.bsky.feed.post/missing-\(suffix)"
    let now = Date()
    let passivePayload = """
      {"commit":{"record":{"$type":"app.bsky.feed.like","subject":{"uri":"\(missingSubject)","cid":"bafymissing"}}}}
      """
    try await pool.query(
      "INSERT INTO wire_ingestion_admission (environment, retained_rows) VALUES (\(environment), 6)",
      logger: logger
    )
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, collection, operation, record_key, payload, event_time, staged_at,
         next_attempt_at, status, applied_at, expires_at)
      VALUES
        (\(environment), \(historyGeneration), 100, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:history-ordinary', NULL, NULL, NULL, '{}'::jsonb, \(now),
         \(now.addingTimeInterval(-7_200)), \(now.addingTimeInterval(-1)),
         'pending', NULL, 'infinity'),
        (\(environment), \(freshGeneration), 200, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:fresh-ordinary', NULL, NULL, NULL, '{}'::jsonb, \(now),
         \(now.addingTimeInterval(-60)), \(now.addingTimeInterval(-1)),
         'pending', NULL, 'infinity'),
        (\(environment), \(historyGeneration), 101, 'test', 'jetstream_v2_seq', 'commit',
         'did:example:history-passive', 'app.bsky.feed.like', 'create', 'like',
         \(passivePayload)::jsonb, \(now), \(now.addingTimeInterval(-7_200)),
         \(now.addingTimeInterval(-1)), 'pending', NULL, 'infinity'),
        (\(environment), \(freshGeneration), 201, 'test', 'jetstream_v2_seq', 'commit',
         'did:example:fresh-passive', 'app.bsky.feed.like', 'create', 'like',
         \(passivePayload)::jsonb, \(now), \(now.addingTimeInterval(-30)),
         \(now.addingTimeInterval(-1)), 'pending', NULL, 'infinity'),
        (\(environment), \(historyGeneration), 102, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:history-terminal', NULL, NULL, NULL, '{}'::jsonb, \(now), \(now),
         \(now), 'applied', \(now.addingTimeInterval(-600)), \(now.addingTimeInterval(-1))),
        (\(environment), \(freshGeneration), 202, 'test', 'jetstream_v2_seq', 'identity',
         'did:example:fresh-terminal', NULL, NULL, NULL, '{}'::jsonb, \(now), \(now),
         \(now), 'applied', \(now.addingTimeInterval(-600)), \(now.addingTimeInterval(-1)))
      """,
      logger: logger
    )

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 1,
      maximumConcurrentEvents: 1,
      sourceScope: WireInboxSourceScope(
        environment: environment, sourceGenerations: [freshGeneration])
    )
    #expect(
      try await processor.acknowledgeUnresolvedPassiveReferences(asOf: now, limit: 10) == 1)

    let health = try await processor.actionableBacklogHealth(asOf: now)
    #expect(health.actionableEventCount == 1)
    let oldestAge = try #require(health.oldestActionableAgeSeconds)
    #expect(oldestAge >= 55 && oldestAge < 120)

    #expect(try await processor.process(asOf: now.addingTimeInterval(1)) == 1)
    #expect(try await processor.deleteTerminal(asOf: now, batchSize: 10) == 1)

    let rows = try await pool.query(
      """
      SELECT source_generation, seq, status
      FROM wire_ingestion_inbox
      WHERE environment = \(environment)
      ORDER BY source_generation, seq
      """,
      logger: logger
    )
    var states: [(String, Int64, String)] = []
    for try await row in rows {
      states.append(try row.decode((String, Int64, String).self))
    }
    #expect(states.count == 5)
    #expect(states.filter { $0.0 == historyGeneration }.map(\.1) == [100, 101, 102])
    #expect(
      states.filter { $0.0 == historyGeneration }.map(\.2) == ["pending", "pending", "applied"])
    #expect(states.filter { $0.0 == freshGeneration }.map(\.1) == [200, 201])
    #expect(states.filter { $0.0 == freshGeneration }.map(\.2) == ["applied", "applied"])

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
    try await pool.query(
      "DELETE FROM wire_ingestion_admission WHERE environment = \(environment)", logger: logger)
  }

  @Test("source-scoped claims preserve FIFO independently per generation and repository")
  func sourceScopedClaimRepositoryFIFO() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-source-scoped-fifo-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-source-scope-fifo-\(UUID().uuidString.lowercased())"
    let firstGeneration = "wire-source-scope-fifo-v1"
    let secondGeneration = "wire-source-scope-fifo-v2"
    let sharedRepo = "did:example:source-scope-shared-\(UUID().uuidString.lowercased())"
    let otherRepo = "did:example:source-scope-other-\(UUID().uuidString.lowercased())"
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time)
      VALUES
        (\(environment), \(firstGeneration), 1, 'test', 'jetstream_v2_seq', 'identity',
         \(sharedRepo), '{}'::jsonb, \(now)),
        (\(environment), \(firstGeneration), 2, 'test', 'jetstream_v2_seq', 'identity',
         \(sharedRepo), '{}'::jsonb, \(now)),
        (\(environment), \(firstGeneration), 3, 'test', 'jetstream_v2_seq', 'identity',
         \(otherRepo), '{}'::jsonb, \(now)),
        (\(environment), \(secondGeneration), 4, 'test', 'jetstream_v2_seq', 'identity',
         \(sharedRepo), '{}'::jsonb, \(now))
      """,
      logger: logger
    )

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 8,
      maximumConcurrentEvents: 8,
      sourceScope: WireInboxSourceScope(
        environment: environment,
        sourceGenerations: [firstGeneration, secondGeneration]
      )
    )
    #expect(try await processor.process(asOf: now) == 3)

    let firstRows = try await pool.query(
      """
      SELECT source_generation, seq, status
      FROM wire_ingestion_inbox
      WHERE environment = \(environment)
      ORDER BY source_generation, seq
      """,
      logger: logger
    )
    var firstStates: [(String, Int64, String)] = []
    for try await row in firstRows {
      firstStates.append(try row.decode((String, Int64, String).self))
    }
    #expect(firstStates.map(\.1) == [1, 2, 3, 4])
    #expect(firstStates.map(\.2) == ["applied", "pending", "applied", "applied"])

    #expect(try await processor.process(asOf: now.addingTimeInterval(1)) == 1)
    let remainingRows = try await pool.query(
      """
      SELECT COUNT(*) FILTER (WHERE status = 'applied')::bigint,
             COUNT(*) FILTER (WHERE status IN ('pending', 'leased', 'retry'))::bigint
      FROM wire_ingestion_inbox
      WHERE environment = \(environment)
      """,
      logger: logger
    )
    for try await row in remainingRows {
      let counts = try row.decode((Int64, Int64).self)
      #expect(counts.0 == 4)
      #expect(counts.1 == 0)
    }

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
  }

  @Test("passive-reference fast path is bounded, ordered, and leaves guarded events alone")
  func passiveReferenceFastPath() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-passive-fast-path-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let suffix = UUID().uuidString.lowercased()
    let environment = "wire-passive-fast-path-\(suffix)"
    let generation = "wire-passive-fast-path-v1"
    let liveSubject = "at://did:example:story/app.bsky.feed.post/live-\(suffix)"
    let missingSubject = "at://did:example:story/app.bsky.feed.post/missing-\(suffix)"
    let canonicalKey = "fast-path-\(suffix)"
    let now = Date()
    let processAt = now.addingTimeInterval(1)
    let likePayload = """
      {"commit":{"record":{"$type":"app.bsky.feed.like","subject":{"uri":"\(missingSubject)","cid":"bafymissing"}}}}
      """
    let repostPayload = """
      {"commit":{"record":{"$type":"app.bsky.feed.repost","subject":"\(missingSubject)"}}}
      """
    let liveLikePayload = """
      {"commit":{"record":{"$type":"app.bsky.feed.like","subject":{"uri":"\(liveSubject)","cid":"bafylive"}}}}
      """
    let recommendationPayload = """
      {"commit":{"record":{"$type":"site.standard.graph.recommend","document":"\(missingSubject)"}}}
      """

    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title,
         first_seen_at, last_seen_at, expires_at)
      VALUES
        (\(canonicalKey), \("https://example.test/\(suffix)"), 'example.test', 'Example',
         'Live story', \(now), \(now), \(now.addingTimeInterval(3_600)))
      """,
      logger: logger
    )
    try await pool.query(
      """
      INSERT INTO wire_item_aliases (alias_key, canonical_key, alias_type, expires_at)
      VALUES (\(liveSubject), \(canonicalKey), 'at_uri', \(now.addingTimeInterval(3_600)))
      """,
      logger: logger
    )
    try await pool.query(
      "INSERT INTO wire_ingestion_admission (environment, retained_rows) VALUES (\(environment), 7)",
      logger: logger
    )
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, collection, operation, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'commit',
         \("did:example:like-\(suffix)"), 'app.bsky.feed.like', 'create', 'like',
         \(likePayload)::jsonb, \(now)),
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'commit',
         \("did:example:repost-\(suffix)"), 'app.bsky.feed.repost', 'update', 'repost',
         \(repostPayload)::jsonb, \(now)),
        (\(environment), \(generation), 3, 'test', 'jetstream_v2_seq', 'commit',
         \("did:example:malformed-\(suffix)"), 'app.bsky.feed.like', 'create', 'malformed',
         '{"commit":{"record":{"$type":"app.bsky.feed.like"}}}'::jsonb, \(now)),
        (\(environment), \(generation), 4, 'test', 'jetstream_v2_seq', 'commit',
         \("did:example:recommend-\(suffix)"), 'site.standard.graph.recommend', 'create', 'recommend',
         \(recommendationPayload)::jsonb, \(now)),
        (\(environment), \(generation), 5, 'test', 'jetstream_v2_seq', 'commit',
         \("did:example:live-like-\(suffix)"), 'app.bsky.feed.like', 'create', 'live-like',
         \(liveLikePayload)::jsonb, \(now)),
        (\(environment), \(generation), 6, 'test', 'jetstream_v2_seq', 'commit',
         \("did:example:delete-\(suffix)"), 'app.bsky.feed.like', 'delete', 'delete',
         \(likePayload)::jsonb, \(now)),
        (\(environment), \(generation), 7, 'test', 'jetstream_v2_seq', 'commit',
         \("did:example:blocked-\(suffix)"), 'app.bsky.feed.like', 'create', 'blocked',
         \(likePayload)::jsonb, \(now))
      """,
      logger: logger
    )
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time)
      VALUES
        (\(environment), \(generation), 0, 'test', 'jetstream_v2_seq', 'identity',
         \("did:example:blocked-\(suffix)"), '{}'::jsonb, \(now))
      """,
      logger: logger
    )
    try await pool.query(
      "UPDATE wire_ingestion_admission SET retained_rows = 8 WHERE environment = \(environment)",
      logger: logger
    )

    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32)
    )
    #expect(
      try await processor.acknowledgeUnresolvedPassiveReferences(
        asOf: processAt, limit: 1) == 1
    )
    #expect(
      try await processor.acknowledgeUnresolvedPassiveReferences(
        asOf: processAt, limit: 5_000) == 1
    )

    let rows = try await pool.query(
      """
      SELECT seq, status, attempt_count, applied_at IS NOT NULL
      FROM wire_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(generation)
      ORDER BY seq
      """,
      logger: logger
    )
    var states: [(Int64, String, Int, Bool)] = []
    for try await row in rows {
      states.append(try row.decode((Int64, String, Int, Bool).self))
    }
    #expect(states.map(\.0) == [0, 1, 2, 3, 4, 5, 6, 7])
    #expect(
      states.map(\.1) == [
        "pending", "applied", "applied", "pending", "pending", "pending", "pending", "pending",
      ])
    #expect(states.map(\.2) == [0, 1, 1, 0, 0, 0, 0, 0])
    #expect(states.map(\.3) == [false, true, true, false, false, false, false, false])

    let admissionRows = try await pool.query(
      """
      SELECT retained_rows FROM wire_ingestion_admission WHERE environment = \(environment)
      """,
      logger: logger
    )
    for try await row in admissionRows { #expect(try row.decode(Int64.self) == 8) }

    _ = try await processor.deleteTerminal(
      asOf: processAt.addingTimeInterval(301), batchSize: 20_000)
    let retainedRows = try await pool.query(
      """
      SELECT retained_rows FROM wire_ingestion_admission WHERE environment = \(environment)
      """,
      logger: logger
    )
    for try await row in retainedRows { #expect(try row.decode(Int64.self) == 6) }

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
    try await pool.query(
      "DELETE FROM wire_ingestion_admission WHERE environment = \(environment)", logger: logger)
    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key = \(canonicalKey)", logger: logger)
  }

  @Test("unresolved passive engagement is applied while high-intent references retry")
  func unresolvedReferencePolicy() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-unresolved-reference-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-unresolved-reference-\(UUID().uuidString.lowercased())"
    let generation = "wire-unresolved-reference-v1"
    let now = Date()
    let missingSubject = "at://did:plc:missing/app.bsky.feed.post/story"
    let likePayload = """
      {"commit":{"record":{"$type":"app.bsky.feed.like","subject":{"uri":"\(missingSubject)","cid":"bafymissing"}}}}
      """
    let repostPayload = """
      {"commit":{"record":{"$type":"app.bsky.feed.repost","subject":{"uri":"\(missingSubject)","cid":"bafymissing"}}}}
      """
    let recommendationPayload = """
      {"commit":{"record":{"$type":"site.standard.graph.recommend","document":"\(missingSubject)"}}}
      """
    let feedbackPayload = """
      {"commit":{"record":{"$type":"app.thesocialwire.wireFeedback","canonicalUrl":"https://missing.example/story","value":"good"}}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, collection, operation, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'commit',
         'did:example:like', 'app.bsky.feed.like', 'create', 'like',
         \(likePayload)::jsonb, \(now)),
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'commit',
         'did:example:repost', 'app.bsky.feed.repost', 'create', 'repost',
         \(repostPayload)::jsonb, \(now)),
        (\(environment), \(generation), 3, 'test', 'jetstream_v2_seq', 'commit',
         'did:example:recommend', 'site.standard.graph.recommend', 'create', 'recommend',
         \(recommendationPayload)::jsonb, \(now)),
        (\(environment), \(generation), 4, 'test', 'jetstream_v2_seq', 'commit',
         'did:example:feedback', 'app.thesocialwire.wireFeedback', 'create', 'feedback',
         \(feedbackPayload)::jsonb, \(now))
      """,
      logger: logger
    )
    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32),
      batchSize: 4,
      maximumConcurrentEvents: 4
    )
    #expect(try await processor.process(asOf: now.addingTimeInterval(1)) == 4)

    let rows = try await pool.query(
      """
      SELECT collection, status, failure_reason
      FROM wire_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(generation)
      ORDER BY seq
      """,
      logger: logger
    )
    var states: [(String?, String, String?)] = []
    for try await row in rows {
      states.append(try row.decode((String?, String, String?).self))
    }
    #expect(
      states.map(\.0) == [
        "app.bsky.feed.like",
        "app.bsky.feed.repost",
        "site.standard.graph.recommend",
        "app.thesocialwire.wireFeedback",
      ]
    )
    #expect(states.map(\.1) == ["applied", "applied", "retry", "retry"])
    #expect(states.map(\.2) == [nil, nil, "unresolved_subject", "unresolved_subject"])

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)",
      logger: logger
    )
  }

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

  @Test("a valid pathless Standard Site document is applied as a no-op")
  func pathlessStandardSiteDocumentAppliesNoOp() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-pathless-standard-site-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-pathless-standard-site-\(UUID().uuidString.lowercased())"
    let generation = "wire-pathless-standard-site-v1"
    let now = Date()
    let payload = """
      {"commit":{"record":{"$type":"site.standard.document","site":"at://did:plc:author/site.standard.publication/main","title":"Valid pathless document","publishedAt":"2026-08-24T00:00:00Z"}}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, collection, operation, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'commit',
         'did:plc:author', 'site.standard.document', 'create', 'pathless',
         \(payload)::jsonb, \(now))
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
      SELECT status, failure_reason, dead_lettered_at
      FROM wire_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(generation) AND seq = 1
      """,
      logger: logger
    )
    for try await row in rows {
      let result = try row.decode((String, String?, Date?).self)
      #expect(result.0 == "applied")
      #expect(result.1 == nil)
      #expect(result.2 == nil)
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
      iterationLimit: 6
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
      maximumConcurrentEvents: 2
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

  @Test("a linkless post update retracts the previously linked article")
  func linklessPostUpdateRetractsSignal() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-linkless-post-update-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let suffix = UUID().uuidString.lowercased()
    let environment = "wire-linkless-update-\(suffix)"
    let generation = "wire-linkless-update-v1"
    let did = "did:plc:linkless-update-\(suffix)"
    let recordKey = "post"
    let sourceURI = "at://\(did)/app.bsky.feed.post/\(recordKey)"
    let articleURL = "https://example.com/linked/\(suffix)"
    let now = Date()
    let createPayload = """
      {"commit":{"record":{"$type":"app.bsky.feed.post","text":"Linked article","embed":{"external":{"uri":"\(articleURL)","title":"Linked article"}}}}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, repo_rev, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'commit', \(did),
         'app.bsky.feed.post', 'create', 'one', \(recordKey), \(createPayload)::jsonb, \(now))
      """,
      logger: logger
    )
    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32)
    )
    #expect(try await processor.process(asOf: now.addingTimeInterval(1)) == 1)

    let canonical = try #require(WireCanonicalizer.canonicalize(articleURL))
    let initialRows = try await pool.query(
      """
      SELECT
        (SELECT COUNT(*)::bigint FROM wire_signal_events
          WHERE canonical_key = \(canonical.canonicalKey)),
        (SELECT COUNT(*)::bigint FROM wire_item_aliases WHERE alias_key = \(sourceURI))
      """,
      logger: logger
    )
    for try await row in initialRows {
      let counts = try row.decode((Int64, Int64).self)
      #expect(counts.0 == 1)
      #expect(counts.1 == 1)
    }

    let updatePayload = """
      {"commit":{"record":{"$type":"app.bsky.feed.post","text":"The link was removed"}}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, repo_rev, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'commit', \(did),
         'app.bsky.feed.post', 'update', 'two', \(recordKey), \(updatePayload)::jsonb,
         \(now.addingTimeInterval(2)))
      """,
      logger: logger
    )
    #expect(try await processor.process(asOf: now.addingTimeInterval(3)) == 1)

    let retractedRows = try await pool.query(
      """
      SELECT
        (SELECT COUNT(*)::bigint FROM wire_signal_events
          WHERE canonical_key = \(canonical.canonicalKey)),
        (SELECT COUNT(*)::bigint FROM wire_item_aliases WHERE alias_key = \(sourceURI))
      """,
      logger: logger
    )
    for try await row in retractedRows {
      let counts = try row.decode((Int64, Int64).self)
      #expect(counts.0 == 0)
      #expect(counts.1 == 0)
    }

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
    try await pool.query(
      "DELETE FROM wire_link_metadata_cache WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)", logger: logger)
    let actorHash = try WireActorHasher(
      secret: Data(String(repeating: "s", count: 32).utf8)
    ).hash(did)
    try await pool.query(
      "DELETE FROM wire_active_actors WHERE actor_key_hash = \(actorHash)", logger: logger)
  }

  @Test("metadata cache seeding progresses beyond the newest conflict window")
  func metadataCacheSeedingProgresses() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-seeding-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let namespace = UUID().uuidString.lowercased()
    let now = Date()
    var canonicalKeys: [String] = []
    for index in 0..<6 {
      let canonicalKey = "url:metadata-seeding-\(namespace)-\(index)"
      canonicalKeys.append(canonicalKey)
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title,
           first_seen_at, last_seen_at, last_signal_at, expires_at)
        VALUES
          (\(canonicalKey), \("https://metadata-\(namespace).example/story/\(index)"),
           \("metadata-\(namespace).example"), 'Metadata Test', \("Story \(index)"),
           \(now), \(now), \(now.addingTimeInterval(Double(index))),
           \(now.addingTimeInterval(86_400)))
        """,
        logger: logger
      )
    }

    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    var claimed = Set<String>()
    for _ in 0..<canonicalKeys.count {
      let targets = try await store.claimDue(limit: 1, asOf: now)
      claimed.formUnion(targets.map(\.canonicalKey))
    }
    #expect(claimed == Set(canonicalKeys))

    let recovered = try await store.claimDue(
      limit: 1,
      asOf: now.addingTimeInterval(301)
    )
    #expect(recovered.count == 1)
    #expect(canonicalKeys.contains(recovered[0].canonicalKey))

    for canonicalKey in canonicalKeys {
      try await pool.query(
        "DELETE FROM wire_items WHERE canonical_key = \(canonicalKey)", logger: logger)
    }
  }
}

private actor IntegrationDrainSleeper: WireInboxDrainSleeping {
  private(set) var delays: [Int] = []
  func sleep(milliseconds: Int) { delays.append(milliseconds) }
}
