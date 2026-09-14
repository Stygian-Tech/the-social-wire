import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

struct WireRecommendationJournalFixture: Sendable {
  let pool: PostgresClient
  let logger: Logger
  let environment = "recommendation-journal-\(UUID().uuidString.lowercased())"
  let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

  var repoDID: String { "did:example:\(environment)" }
  var sourceURI: String { "at://\(repoDID)/site.standard.graph.recommend/recommendation" }
  var scope: WireInboxSourceScope {
    WireInboxSourceScope(environment: environment, sourceGenerations: ["live", "replay"])
  }
  var journal: PostgresWireRecommendationJournal {
    PostgresWireRecommendationJournal(pool: pool, logger: logger)
  }

  func processor(enabled: Bool = true, scoped: Bool = true) throws -> PostgresWireInboxProcessor {
    try PostgresWireInboxProcessor(
      pool: pool, logger: logger, actorSecret: String(repeating: "s", count: 32),
      sourceScope: scoped ? scope : nil, deferredRecommendationsEnabled: enabled)
  }

  func subject(_ name: String = "first") -> String {
    "at://\(repoDID)/site.standard.document/\(name)"
  }

  func insertRecommendation(
    sequence: Int64, operation: String = "create", subject: String? = nil,
    generation: String = "live", occurredAt: Date? = nil, revision: String? = nil,
    sourceHost: String = "test"
  ) async throws {
    let eventTime = occurredAt ?? now.addingTimeInterval(Double(sequence))
    let rev = revision ?? "3m2222222222\(Array("234567abcdefghijklmnopqrstuvwxyz")[Int(sequence) % 32])"
    let payload = try String(
      decoding: JSONSerialization.data(withJSONObject: [
        "commit": [
          "rev": rev,
          "record": ["$type": "site.standard.graph.recommend", "document": subject ?? self.subject()],
        ]
      ]), as: UTF8.self)
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, repo_rev, record_key, payload, event_time, next_attempt_at)
      VALUES (\(environment), \(generation), \(sequence), \(sourceHost), 'jetstream_v2_seq', 'commit',
              \(repoDID), 'site.standard.graph.recommend', \(operation), \(rev), 'recommendation',
              \(payload)::jsonb, \(eventTime), \(now))
      """, logger: logger)
  }

  func claim(sequence: Int64, generation: String = "live", asOf: Date? = nil) async throws -> WireInboxEvent {
    let event = try #require(
      try await processor().claimNext(
        in: WireInboxRepository(environment: environment, sourceGeneration: generation, repoDID: repoDID),
        asOf: asOf ?? now.addingTimeInterval(60)))
    #expect(event.sequence == sequence)
    return event
  }

  func apply(sequence: Int64, generation: String = "live", asOf: Date? = nil) async throws -> WireInboxEventOutcome {
    let processAt = asOf ?? now.addingTimeInterval(60)
    let event = try await claim(sequence: sequence, generation: generation, asOf: processAt)
    return try await processor().applyClaimed(event, asOf: processAt)
  }

  func publishSubject(_ name: String = "first") async throws -> String {
    let key = "\(environment)-\(name)"
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title,
         first_seen_at, last_seen_at, expires_at)
      VALUES (\(key), \("https://example.test/" + key), 'example.test', 'Example',
              'Deferred Recommendation Test', \(now), \(now), \(now.addingTimeInterval(14 * 86_400)))
      """, logger: logger)
    try await pool.query(
      """
      INSERT INTO wire_item_aliases (alias_key, canonical_key, alias_type, expires_at)
      VALUES (\(subject(name)), \(key), 'at_uri', \(now.addingTimeInterval(14 * 86_400)))
      """, logger: logger)
    return key
  }

  func recover(asOf: Date? = nil) async throws -> WireRecommendationRecoveryCounts {
    try await journal.recover(asOf: asOf ?? now.addingTimeInterval(600), limit: 100, sourceScope: scope)
  }

  func scalar(_ query: PostgresQuery) async throws -> Int64 {
    for try await row in try await pool.query(query, logger: logger) {
      return try row.decode(Int64.self)
    }
    throw FixtureError.noRow
  }

  func journalStatus(sequence: Int64, generation: String = "live") async throws -> String? {
    let rows = try await pool.query(
      """
      SELECT status FROM wire_recommendation_journal
      WHERE environment = \(environment) AND source_generation = \(generation) AND seq = \(sequence)
      """, logger: logger)
    for try await row in rows { return try row.decode(String.self) }
    return nil
  }

  func signalCount() async throws -> Int64 {
    try await scalar("SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(sourceURI)")
  }

  func actorSignalCount() async throws -> Int64 {
    let hash = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8)).hash(repoDID)
    return try await scalar(
      "SELECT public_signal_count::bigint FROM wire_active_actors WHERE actor_key_hash = \(hash)")
  }

  func clean() async throws {
    try await pool.query("DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
    try await pool.query("DELETE FROM wire_ingestion_admission WHERE environment = \(environment)", logger: logger)
    try await pool.query("DELETE FROM wire_recommendation_record_fences WHERE environment = \(environment)", logger: logger)
    try await pool.query("DELETE FROM wire_recommendation_journal WHERE environment = \(environment)", logger: logger)
    try await pool.query("DELETE FROM wire_recommendation_account_fences WHERE environment = \(environment)", logger: logger)
    try await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(environment + "%") OR author_key = \(repoDID)", logger: logger)
    try await pool.query("DELETE FROM wire_publications WHERE repo_did = \(repoDID)", logger: logger)
    let hash = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8)).hash(repoDID)
    try await pool.query("DELETE FROM wire_active_actors WHERE actor_key_hash = \(hash)", logger: logger)
  }

  static func run(_ operation: (Self) async throws -> Void) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-recommendation-journal.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 8, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let fixture = Self(pool: pool, logger: logger)
    do {
      try await operation(fixture)
      try await fixture.clean()
    } catch {
      logger.error("Recommendation journal integration failed", metadata: ["error": .string(String(reflecting: error))])
      try? await fixture.clean()
      throw error
    }
  }

  private enum FixtureError: Error { case noRow }
}
