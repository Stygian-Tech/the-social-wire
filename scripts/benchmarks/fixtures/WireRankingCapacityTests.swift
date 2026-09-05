// Copy unchanged into each exact revision's Tests/WireWorkerTests directory.
// Synthetic capacity fixture: these are invented .invalid stories and actors,
// not public replay events, observed popularity, or a production distribution.
import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

@Suite("Synthetic Wire 5000 candidate capacity", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["WIRE_CAPACITY_DATABASE_URL"] != nil))
struct WireRankingCapacityTests {
  @Test("real rollups, ranking and persistence over a deterministic synthetic corpus")
  func capacity() async throws {
    let environment = ProcessInfo.processInfo.environment
    let rawURL = try #require(environment["WIRE_CAPACITY_DATABASE_URL"])
    let output = try #require(environment["WIRE_CAPACITY_OUTPUT"])
    let revision = try #require(environment["WIRE_CAPACITY_REVISION"])
    guard revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
      output.hasPrefix("/"), !FileManager.default.fileExists(atPath: output)
    else { throw CapacityFailure.invalidConfiguration }
    try validateTarget(rawURL)
    let logger = Logger(label: "wire.synthetic-capacity")
    let postgres = try PostgresWireConfig.make(from: rawURL, logger: logger)
    let pool = PostgresClient(configuration: postgres, backgroundLogger: logger)
    let poolTask = Task { await pool.run() }
    defer { poolTask.cancel() }
    // Task cancellation plus the outer runner's process timeout bound failures.
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask {
        try await Self.runTrial(pool: pool, logger: logger, rawURL: rawURL,
          revision: revision, output: output)
      }
      tasks.addTask {
        try await Task.sleep(for: .seconds(120))
        throw CapacityFailure.deadline
      }
      do {
        _ = try await tasks.next()
        tasks.cancelAll()
      } catch {
        tasks.cancelAll()
        throw error
      }
    }
  }

  private func validateTarget(_ rawURL: String) throws {
    guard let url = URLComponents(string: rawURL),
      ["postgres", "postgresql"].contains(url.scheme ?? ""),
      let host = url.host,
      url.fragment == nil,
      url.path.range(of: "^/tsw92_bench_[a-f0-9]{12}$", options: .regularExpression) != nil
    else { throw CapacityFailure.unsafeTarget }
    let parameters = url.queryItems ?? []
    let sslModes = ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"]
    guard parameters.count <= 1,
      parameters.allSatisfy({ $0.name == "sslmode" && sslModes.contains($0.value ?? "") })
    else { throw CapacityFailure.unsafeTarget }
    let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
      && url.port != nil && url.port != 5432 && url.port != 0
    let railway = host.range(of: "^tsw92-[a-z0-9-]+\\.railway\\.internal$",
      options: .regularExpression) != nil
    guard loopback || railway else { throw CapacityFailure.unsafeTarget }
  }

  private static func runTrial(pool: PostgresClient, logger: Logger, rawURL: String,
    revision: String, output: String) async throws {
    let started = ContinuousClock.now
    let fixedAsOf = Date(timeIntervalSince1970: 1_788_566_400)
    let empty = try await pool.query(
      """
      SELECT (SELECT COUNT(*) FROM wire_items) + (SELECT COUNT(*) FROM wire_signal_events)
        + (SELECT COUNT(*) FROM wire_rank_generations) + (SELECT COUNT(*) FROM wire_labels)
        + (SELECT COUNT(*) FROM wire_label_refresh_state) + (SELECT COUNT(*) FROM wire_feed_state)
        + (SELECT COUNT(*) FROM wire_active_actors) + (SELECT COUNT(*) FROM wire_follow_edges)
        + (SELECT COUNT(*) FROM wire_actor_communities)
      """, logger: logger)
    for try await row in empty {
      guard try row.decode(Int64.self) == 0 else { throw CapacityFailure.nonemptyDatabase }
    }
    let initial = try await counters(pool: pool, logger: logger)
    try checkBudget(initial, started: started)
    try await seed(pool: pool, logger: logger, asOf: fixedAsOf)
    // Catalog estimates are refreshed before both measurements in the same way.
    try await pool.query("ANALYZE wire_items", logger: logger)
    try await pool.query("ANALYZE wire_signal_events", logger: logger)
    try await pool.query("ANALYZE wire_link_metadata_cache", logger: logger)
    let secret = "synthetic-capacity-only-actor-secret-000000000000"
    let config = try WireWorkerConfig.load([
      "DATABASE_URL": rawURL, "WIRE_FEED_MODE": "api", "WIRE_WORKER_ROLE": "rank",
      "WIRE_EXTERNAL_SIGNAL_MODE": "off", "WIRE_ACTOR_HMAC_SECRET": secret,
      "WIRE_CANDIDATE_LIMIT": "5000", "WIRE_LANGUAGE_BUCKET": "und",
      "WIRE_RANK_INTERVAL_SECONDS": "300", "WIRE_GENERATION_RETENTION_SECONDS": "7200",
    ])
    let store = PostgresWireGenerationStore(pool: pool, logger: logger)
    let maintainer = try PostgresWireInboxProcessor(pool: pool, logger: logger, actorSecret: secret)
    let labels = CapacitySyntheticAllowSnapshot(pool: pool, logger: logger)
    let cycle = WireWorkerCycle(store: store, config: config,
      inboxMaintainer: maintainer, labelRefresher: labels)
    var measurements: [CapacityCycleMeasurement] = []
    // Allow setup transactions' statistics to flush before measuring cycles.
    // The insertion LSN still supplies an exact cluster WAL boundary separately.
    try await Task.sleep(for: .milliseconds(1200))
    let before = try await counters(pool: pool, logger: logger)
    for index in 0..<3 {
      try Task.checkCancellation()
      let cycleBefore = try await counters(pool: pool, logger: logger)
      try checkBudget(cycleBefore, started: started)
      let cycleStarted = ContinuousClock.now
      let result = try await cycle.run(asOf: fixedAsOf)
      let duration = milliseconds(cycleStarted.duration(to: .now))
      guard case .generated(let generationID, let count, let active) = result,
        count == 5000, active
      else { throw CapacityFailure.cardinalityMismatch }
      let rows = try await pool.query(
        """
        SELECT candidate_count, ranked_count,
          (SELECT COUNT(*) FROM wire_ranked_items WHERE generation_id = \(generationID)),
          (SELECT COUNT(*) FROM wire_signal_rollups),
          (SELECT COUNT(*) FROM wire_signal_events)
        FROM wire_rank_generations WHERE generation_id = \(generationID)
        """, logger: logger)
      var found = false
      for try await row in rows {
        let counts = try row.decode((Int, Int, Int64, Int64, Int64).self)
        guard counts.0 == 5000, counts.1 == 5000, counts.2 == 5000,
          counts.3 == 5000, counts.4 == 25000
        else { throw CapacityFailure.cardinalityMismatch }
        found = true
      }
      guard found else { throw CapacityFailure.cardinalityMismatch }
      let cycleAfter = try await counters(pool: pool, logger: logger)
      try checkBudget(cycleAfter, started: started)
      guard cycleBefore.statsReset == cycleAfter.statsReset,
        cycleAfter.walBytes >= cycleBefore.walBytes
      else { throw CapacityFailure.counterReset }
      measurements.append(CapacityCycleMeasurement(index: index, durationMilliseconds: duration,
        candidateCount: 5000, rankedCount: 5000, rankedRows: 5000, rollupRows: 5000,
        signalRows: 25000, before: cycleBefore, after: cycleAfter))
    }
    try await Task.sleep(for: .milliseconds(1200))
    let after = try await counters(pool: pool, logger: logger)
    guard before.statsReset == after.statsReset, after.walBytes >= before.walBytes
    else { throw CapacityFailure.counterReset }
    let lsnRows = try await pool.query(
      "SELECT pg_wal_lsn_diff(\(after.walInsertLSN)::pg_lsn, \(before.walInsertLSN)::pg_lsn)::bigint",
      logger: logger)
    var insertedWAL: Int64 = 0
    for try await row in lsnRows { insertedWAL = try row.decode(Int64.self) }
    let evidence = CapacityEvidence(kind: "synthetic-5000-cardinality-capacity", revision: revision,
      fixtureVersion: 1, status: "passed", fixedAsOfUnixSeconds: fixedAsOf.timeIntervalSince1970,
      disclaimer: "Invented stories and actors. No real replay, popularity, distribution, HTTP enrichment, or cadence claim. All three cycles are measured; the first is cold.",
      before: before, after: after, walStatsDeltaBytes: after.walBytes - before.walBytes,
      walInsertLSNDeltaBytes: insertedWAL, cycles: measurements)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(evidence).write(to: URL(fileURLWithPath: output), options: .atomic)
    // The enclosing harness owns this fresh random database and drops it after
    // the test process exits. Never remove arbitrary rows or other databases here.
  }

  private static func seed(pool: PostgresClient, logger: Logger, asOf: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SET LOCAL statement_timeout='20s'", logger: logger)
      try await connection.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title, summary,
           language_code, first_seen_at, last_seen_at, last_signal_at, published_at,
           expires_at, source_confidence, eligible, target_kind, commercial_class)
        SELECT 'capacity-' || n, 'https://source-' || (n % 100) || '.invalid/story/' || n,
          'source-' || (n % 100) || '.invalid', 'Synthetic Source ' || (n % 100),
          'Synthetic capacity story ' || n, 'Explicit synthetic cardinality fixture.',
          'und', \(asOf.addingTimeInterval(-3600)), \(asOf), \(asOf),
          \(asOf.addingTimeInterval(-3600)), \(asOf.addingTimeInterval(86400)),
          0.9, TRUE, 'external_article', 'normal'
        FROM generate_series(1, 5000) n
        """, logger: logger)
      try await connection.query(
        """
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, title, description, source, status,
           fetched_at, fresh_until, stale_until, retry_after, language_checked_at)
        SELECT canonical_key, canonical_url, title, summary, 'open_graph', 'fresh',
          \(asOf), \(asOf.addingTimeInterval(86400)), \(asOf.addingTimeInterval(172800)),
          \(asOf.addingTimeInterval(86400)), \(asOf)
        FROM wire_items
        """, logger: logger)
      try await connection.query(
        "SELECT ensure_wire_signal_event_partition(\(asOf)::timestamptz::date)", logger: logger)
      try await connection.query(
        """
        INSERT INTO wire_signal_events
          (event_key, canonical_key, signal_kind, actor_key_hash, source_uri,
           occurred_at, ingested_at, expires_at, source_collection, source_action)
        SELECT 'capacity-event-' || item || '-' || actor, 'capacity-' || item, 'share',
          'synthetic-capacity-actor-' || item || '-' || actor,
          'at://did:example:capacity-' || item || '-' || actor || '/app.bsky.feed.post/fixture',
          \(asOf), \(asOf), \(asOf.addingTimeInterval(604800)), 'app.bsky.feed.post', 'create'
        FROM generate_series(1, 5000) item CROSS JOIN generate_series(1, 5) actor
        """, logger: logger)
      try await connection.query(
        """
        INSERT INTO wire_label_refresh_state
          (source_did, endpoint_host, last_attempted_at, last_successful_at,
           target_count, label_count, is_current)
        VALUES ('did:example:synthetic-capacity-labeler', 'synthetic-labels.invalid',
          \(asOf), \(asOf), 5000, 0, TRUE)
        """, logger: logger)
    }
  }

  private static func counters(pool: PostgresClient, logger: Logger) async throws -> CapacityCounters {
    let rows = try await pool.query(
      """
      SELECT wal_bytes::bigint, COALESCE(stats_reset::text, 'unset'),
        pg_database_size(current_database()),
        (SELECT COALESCE(SUM(size), 0)::bigint FROM pg_ls_waldir()),
        pg_current_wal_insert_lsn()::text
      FROM pg_stat_wal
      """, logger: logger)
    for try await row in rows {
      let value = try row.decode((Int64, String, Int64, Int64, String).self)
      return CapacityCounters(walBytes: value.0, statsReset: value.1,
        databaseBytes: value.2, walDirectoryBytes: value.3, walInsertLSN: value.4)
    }
    throw CapacityFailure.missingCounters
  }

  private static func checkBudget(_ counters: CapacityCounters, started: ContinuousClock.Instant) throws {
    guard counters.databaseBytes + counters.walDirectoryBytes < 2_147_483_648 else {
      throw CapacityFailure.byteCap
    }
    guard started.duration(to: .now) < .seconds(120) else { throw CapacityFailure.deadline }
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
  }
}

private struct CapacitySyntheticAllowSnapshot: WireBaselineLabelRefreshing {
  let pool: PostgresClient
  let logger: Logger

  func refresh(asOf: Date) async throws {
    let rows = try await pool.query(
      """
      SELECT target_count, label_count, (SELECT COUNT(*) FROM wire_labels)
      FROM wire_label_refresh_state
      WHERE source_did = 'did:example:synthetic-capacity-labeler'
        AND endpoint_host = 'synthetic-labels.invalid' AND is_current
        AND last_successful_at = \(asOf)
      """, logger: logger)
    for try await row in rows {
      let value = try row.decode((Int, Int, Int64).self)
      guard value.0 == 5000, value.1 == 0, value.2 == 0 else { throw CapacityFailure.invalidSyntheticLabels }
      return
    }
    throw CapacityFailure.invalidSyntheticLabels
  }
}

private enum CapacityFailure: Error {
  case unsafeTarget, invalidConfiguration, nonemptyDatabase, deadline, byteCap
  case cardinalityMismatch, counterReset, missingCounters, invalidSyntheticLabels
}

private struct CapacityCounters: Codable {
  let walBytes: Int64
  let statsReset: String
  let databaseBytes: Int64
  let walDirectoryBytes: Int64
  let walInsertLSN: String
}

private struct CapacityCycleMeasurement: Codable {
  let index: Int
  let durationMilliseconds: Double
  let candidateCount: Int
  let rankedCount: Int
  let rankedRows: Int
  let rollupRows: Int
  let signalRows: Int
  let before: CapacityCounters
  let after: CapacityCounters
}

private struct CapacityEvidence: Codable {
  let kind: String
  let revision: String
  let fixtureVersion: Int
  let status: String
  let fixedAsOfUnixSeconds: Double
  let disclaimer: String
  let before: CapacityCounters
  let after: CapacityCounters
  let walStatsDeltaBytes: Int64
  let walInsertLSNDeltaBytes: Int64
  let cycles: [CapacityCycleMeasurement]
}
