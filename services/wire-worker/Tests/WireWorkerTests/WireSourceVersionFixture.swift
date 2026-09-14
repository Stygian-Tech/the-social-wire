import Foundation
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

struct WireSourceVersionFixture: Sendable {
  static let olderRevision = "3m22222222223"
  static let newerRevision = "3m22222222225"
  static let olderCID = "bafyreidvz67ncib33pu5xmu4a27v3ja7k2dtctflvutfo3ml7a4p4jptz4"
  static let newerCID = "bafyreif2o444riqelx6ezgzlcnmfimbxdd6t676cozuwmwf5tkx674cyta"

  let base: WireRecommendationJournalFixture
  let collection: String
  let author: String

  init(base: WireRecommendationJournalFixture, collection: String = "site.standard.document", author: String? = nil) {
    self.base = base
    self.collection = collection
    self.author = author ?? base.repoDID
  }

  var sourceURI: String { "at://\(author)/\(collection)/record" }
  var url: String { "https://\(author.replacingOccurrences(of: ":", with: "-")).example.test/fenced" }
  var key: String { WireCanonicalizer.canonicalize(url)!.canonicalKey }

  func insert(
    sequence: Int64, revision: String, title: String = "Older Article",
    snapshot: Bool = false, operation: String = "update", generation: String = "live",
    cid: String? = nil, occurredAt: Date? = nil, sourceHost: String? = nil
  ) async throws {
    let recordCID = operation == "delete" ? nil : cid ?? (revision == Self.olderRevision ? Self.olderCID : Self.newerCID)
    let record = collection == "site.standard.publication"
      ? ["$type": collection, "url": url, "name": title]
      : ["$type": collection, "url": url, "title": title,
         "publishedAt": base.now.addingTimeInterval(-30 * 86_400).ISO8601Format()]
    let contents: [String: Any]
    if snapshot {
      contents = ["snapshot": ["record": record, "cid": recordCID ?? "", "rev": revision]]
    } else {
      contents = ["commit": ["record": record, "rev": revision]]
    }
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: contents), as: UTF8.self)
    try await base.pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, record_key, record_cid, repo_rev, payload, event_time, next_attempt_at)
      VALUES (\(base.environment), \(generation), \(sequence),
              \(sourceHost ?? (snapshot ? "https://pds.example.test" : "jetstream.example.test")),
              \(snapshot ? "pds_record_snapshot" : "jetstream_v2_seq"),
              \(snapshot ? "snapshot" : "commit"), \(author), \(collection), \(operation),
              'record', \(recordCID), \(revision), \(payload)::jsonb,
              \(occurredAt ?? base.now.addingTimeInterval(Double(sequence))), \(base.now))
      """, logger: base.logger)
  }

  func claim(sequence: Int64, generation: String = "live") async throws -> WireInboxEvent {
    let event = try #require(try await base.processor().claimNext(
      in: WireInboxRepository(environment: base.environment, sourceGeneration: generation, repoDID: author),
      asOf: base.now.addingTimeInterval(60)))
    #expect(event.sequence == sequence)
    return event
  }

  func insertAccount(sequence: Int64, active: Bool, occurredAt: Date) async throws {
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
      "account": ["active": active]
    ]), as: UTF8.self)
    try await base.pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         payload, event_time, next_attempt_at)
      VALUES (\(base.environment), 'live', \(sequence), 'jetstream.example.test', 'jetstream_v2_seq',
              'account', \(author), \(payload)::jsonb, \(occurredAt), \(base.now))
      """, logger: base.logger)
  }

  func apply(sequence: Int64, generation: String = "live") async throws -> WireInboxEventOutcome {
    try await base.processor().applyClaimed(
      claim(sequence: sequence, generation: generation), asOf: base.now.addingTimeInterval(60))
  }

  func projectionExists() async throws -> Bool {
    let query: PostgresQuery = collection == "site.standard.publication"
      ? "SELECT COUNT(*)::bigint FROM wire_publications WHERE publication_uri = \(sourceURI)"
      : "SELECT COUNT(*)::bigint FROM wire_item_aliases WHERE alias_key = \(sourceURI)"
    return try await base.scalar(query) == 1
  }

  func title() async throws -> String? {
    let query: PostgresQuery = collection == "site.standard.publication"
      ? "SELECT name FROM wire_publications WHERE publication_uri = \(sourceURI)"
      : "SELECT title FROM wire_items WHERE canonical_key = \(key)"
    for try await row in try await base.pool.query(query, logger: base.logger) {
      return try row.decode(String.self)
    }
    return nil
  }

  func signalCount() async throws -> Int64 {
    try await base.scalar("SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(sourceURI)")
  }

  func actorSignals() async throws -> Int64 {
    let hash = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8)).hash(author)
    return try await base.scalar(
      "SELECT COALESCE(SUM(public_signal_count), 0)::bigint FROM wire_active_actors WHERE actor_key_hash = \(hash)")
  }

  static func run(
    collection: String = "site.standard.document",
    _ operation: (Self) async throws -> Void
  ) async throws {
    try await WireRecommendationJournalFixture.run { base in
      let fixture = Self(base: base, collection: collection)
      do {
        try await operation(fixture)
        try await base.pool.query(
          "DELETE FROM wire_standard_record_fences WHERE environment = \(base.environment)", logger: base.logger)
      } catch {
        _ = try? await base.pool.query(
          "DELETE FROM wire_standard_record_fences WHERE environment = \(base.environment)", logger: base.logger)
        throw error
      }
    }
  }
}
