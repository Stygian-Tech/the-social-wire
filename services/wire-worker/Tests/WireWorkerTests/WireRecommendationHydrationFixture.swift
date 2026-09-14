import Foundation
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

struct WireRecommendationHydrationFixture: Sendable {
  let base: WireRecommendationJournalFixture
  let verifier: WireHydrationVerifierFixture

  private var identitySeed: String {
    String(base.environment.suffix(36)).replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "0", with: "g").replacingOccurrences(of: "1", with: "h")
      .replacingOccurrences(of: "8", with: "i").replacingOccurrences(of: "9", with: "j")
  }
  var authorDID: String { "did:plc:\(identitySeed.prefix(24))" }
  var readerDID: String { "did:plc:\(identitySeed.suffix(24))" }
  var subjectURI: String { "at://\(authorDID)/site.standard.document/article" }
  var url: String { "https://\(base.environment).example.test/article" }
  var key: String { WireCanonicalizer.canonicalize(url)!.canonicalKey }
  var cid: String { WireSourceVersionFixture.olderCID }
  var revision: String { WireSourceVersionFixture.newerRevision }
  var scope: WireInboxSourceScope {
    WireInboxSourceScope(environment: base.environment, sourceGenerations: [])
  }

  func sourceURI(_ sequence: Int64 = 1) -> String {
    "at://\(readerDID)/site.standard.graph.recommend/recommendation-\(sequence)"
  }

  func processor() throws -> PostgresWireInboxProcessor {
    try PostgresWireInboxProcessor(pool: base.pool, logger: base.logger,
      actorSecret: String(repeating: "s", count: 32), deferredRecommendationsEnabled: true,
      dependencyVerificationEnabled: true)
  }

  func recommendation(_ sequence: Int64 = 1, subject: String? = nil, observedAt: Date? = nil) throws -> WireVerifiedPublicRecord {
    try record(uri: sourceURI(sequence), body: [
      "$type": "site.standard.graph.recommend", "document": subject ?? subjectURI,
    ], observedAt: observedAt)
  }

  func document(observedAt: Date? = nil) throws -> WireVerifiedPublicRecord {
    try record(uri: subjectURI, body: [
      "$type": "site.standard.document", "url": url, "title": "Recovered Dependency",
      "publishedAt": ISO8601DateFormatter().string(from: base.now.addingTimeInterval(-86_400)),
    ], observedAt: observedAt)
  }

  func record(uri: String, body: [String: String], observedAt: Date? = nil) throws -> WireVerifiedPublicRecord {
    let reference = try WirePublicRecordReference(uri)
    return WireVerifiedPublicRecord(uri: uri, repoDID: reference.repoDID,
      collection: reference.collection, recordKey: reference.recordKey, cid: cid,
      repositoryRevision: revision, pdsBase: "https://pds.example.test",
      recordJSON: try JSONSerialization.data(withJSONObject: body), observedAt: observedAt ?? base.now)
  }

  func observation(_ sequence: Int64 = 1) -> WirePublicRecordObservation {
    WirePublicRecordObservation(uri: sourceURI(sequence), expectedCID: cid,
      repositoryRevision: revision, pdsBase: "https://pds.example.test", observedAt: base.now)
  }

  func seed(_ sequence: Int64 = 1, subject: String? = nil) async throws {
    let verified = try recommendation(sequence, subject: subject)
    let payload = "{\"commit\":{\"rev\":\"\(revision)\",\"record\":\(String(decoding: verified.recordJSON, as: UTF8.self))}}"
    try await base.pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, repo_rev, record_cid, record_key, payload, event_time, next_attempt_at)
      VALUES (\(base.environment), 'live', \(sequence), 'jetstream.example.test', 'jetstream_v2_seq', 'commit',
        \(readerDID), 'site.standard.graph.recommend', 'create', \(revision), \(cid),
        \("recommendation-\(sequence)"), \(payload)::jsonb, \(base.now.addingTimeInterval(-3_600)), \(base.now))
      """, logger: base.logger)
    let event = try #require(try await processor().claimNext(
      in: WireInboxRepository(environment: base.environment, sourceGeneration: "live", repoDID: readerDID),
      asOf: base.now))
    #expect(event.sequence == sequence)
    #expect(try await processor().applyClaimed(event, asOf: base.now) == .deferred)
    try await base.pool.query(
      """
      UPDATE wire_recommendation_journal SET next_attempt_at = \(base.now)
      WHERE environment = \(base.environment) AND source_generation = 'live' AND seq = \(sequence)
      """, logger: base.logger)
    await verifier.set(.verified(verified), for: sourceURI(sequence))
    await verifier.set(.verified(try document()), for: subjectURI)
  }

  func signalCount() async throws -> Int64 {
    try await base.scalar("SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri LIKE \("at://" + readerDID + "/%")")
  }

  func preseedItem(alias: Bool = true) async throws {
    try await base.pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title, eligible,
         first_seen_at, last_seen_at, last_signal_at, expires_at)
      VALUES (\(key), \(url), 'example.test', 'Fixture', 'Existing Dependency', FALSE,
        \(base.now.addingTimeInterval(-86_400)), \(base.now.addingTimeInterval(-86_400)),
        \(base.now.addingTimeInterval(-7_200)), \(base.now.addingTimeInterval(86_400)))
      """, logger: base.logger)
    if alias {
      try await base.pool.query(
        """
        INSERT INTO wire_item_aliases (alias_key, canonical_key, alias_type, expires_at)
        VALUES (\(subjectURI), \(key), 'at_uri', \(base.now.addingTimeInterval(86_400)))
        """, logger: base.logger)
    }
  }

  func applySnapshots(asOf: Date? = nil) async throws {
    let rows = try await base.pool.query(
      """
      SELECT DISTINCT source_generation, repo_did FROM wire_ingestion_inbox
      WHERE environment = \(base.environment) AND event_kind = 'snapshot'
      """, logger: base.logger)
    for try await row in rows {
      let (generation, did) = try row.decode((String, String).self)
      let repository = WireInboxRepository(environment: base.environment, sourceGeneration: generation, repoDID: did)
      for _ in 0..<8 {
        guard let event = try await processor().claimNext(in: repository, asOf: asOf ?? base.now) else { break }
        #expect(try await processor().applyClaimed(event, asOf: asOf ?? base.now) == .applied)
      }
    }
  }

  func clean() async throws {
    try await base.pool.query("DELETE FROM wire_recommendation_dependency_recovery WHERE environment = \(base.environment)", logger: base.logger)
    try await base.pool.query("DELETE FROM wire_standard_record_fences WHERE environment = \(base.environment)", logger: base.logger)
    try await base.pool.query("DELETE FROM wire_items WHERE canonical_key = \(key) OR author_key = \(authorDID)", logger: base.logger)
    try await base.pool.query("DELETE FROM wire_publications WHERE repo_did = \(authorDID)", logger: base.logger)
    let hasher = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8))
    for did in [authorDID, readerDID] {
      try await base.pool.query("DELETE FROM wire_active_actors WHERE actor_key_hash = \(hasher.hash(did))", logger: base.logger)
    }
  }

  static func run(
    verifier: WireHydrationVerifierFixture = WireHydrationVerifierFixture(),
    _ operation: (Self) async throws -> Void
  ) async throws {
    try await WireRecommendationJournalFixture.run { base in
      let fixture = Self(base: base, verifier: verifier)
      do {
        try await operation(fixture)
        try await fixture.clean()
      } catch {
        try? await fixture.clean()
        throw error
      }
    }
  }
}
