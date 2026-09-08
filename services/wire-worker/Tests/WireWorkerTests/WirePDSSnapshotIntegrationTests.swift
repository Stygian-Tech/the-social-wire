import Foundation
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("PDS snapshots hydrate real document aliases without inventing publication activity")
  func pdsSnapshotResolvesDeferredRecommendation() async throws {
    try await WireRecommendationJournalFixture.runPDSSnapshot { fixture in
      try await fixture.insertRecommendation(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .deferred)
      let publication = "at://\(fixture.repoDID)/site.standard.publication/publication"
      try await fixture.insertPDSSnapshot(sequence: 2, collection: "site.standard.publication",
        key: "publication", fields: ["url": fixture.snapshotURL, "name": "Snapshot Publication"])
      #expect(try await fixture.apply(sequence: 2) == .applied)
      let publishedAt = fixture.now.addingTimeInterval(-30 * 86_400)
      try await fixture.insertPDSSnapshot(sequence: 3, fields: [
        "title": "An Authoritative Older Article", "site": publication, "path": "/article",
        "publishedAt": ISO8601DateFormatter().string(from: publishedAt), "lang": "en",
      ])
      let event = try await fixture.claim(sequence: 3)
      #expect(try await fixture.processor().applyClaimed(event, asOf: fixture.now.addingTimeInterval(60)) == .applied)
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_item_aliases alias JOIN wire_items item USING (canonical_key)
        WHERE alias.alias_key = \(fixture.subject())
          AND item.canonical_url = \(fixture.snapshotURL + "/article")
          AND item.title = 'An Authoritative Older Article' AND item.published_at = \(publishedAt)
          AND item.publication_id = \(publication) AND item.source_name = 'Snapshot Publication'
          AND item.target_kind = 'standard_site_document' AND item.last_signal_at IS NULL
        """) == 1)
      #expect(try await fixture.snapshotActorCount() == 0)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE source_uri = \(fixture.subject())") == 0)
      #expect(try await fixture.processor().applyClaimed(event, asOf: fixture.now.addingTimeInterval(61)) == .leaseLost)
      let recovered = try await fixture.recover()
      #expect(recovered.resolved == 1)
      #expect(try await fixture.signalCount() == 1)
      #expect(try await fixture.actorSignalCount() == 1)
    }
  }

  @Test("legacy standard entries use the same snapshot projection and preserve existing eligibility")
  func pdsSnapshotPreservesModerationAndSignalTime() async throws {
    try await WireRecommendationJournalFixture.runPDSSnapshot { fixture in
      let collection = "site.standard.entry"
      try await fixture.insertPDSSnapshot(sequence: 1, collection: collection)
      #expect(try await fixture.apply(sequence: 1) == .applied)
      let oldSignalTime = fixture.now.addingTimeInterval(-3 * 86_400)
      try await fixture.pool.query(
        "UPDATE wire_items SET eligible = FALSE, last_signal_at = \(oldSignalTime) WHERE author_key = \(fixture.repoDID)",
        logger: fixture.logger)
      try await fixture.insertPDSSnapshot(sequence: 2, collection: collection)
      #expect(try await fixture.apply(sequence: 2) == .applied)
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_items
        WHERE author_key = \(fixture.repoDID) AND eligible = FALSE AND last_signal_at = \(oldSignalTime)
        """) == 1)
      #expect(try await fixture.snapshotActorCount() == 0)
    }
  }

  @Test("invalid snapshot transport, record type and retained identity fail closed",
    arguments: ["cursor", "eventKind", "operation", "collection", "recordType", "cid", "rev", "missingRev"])
  func pdsSnapshotRejectsInvalidIdentity(_ invalid: String) async throws {
    try await WireRecommendationJournalFixture.runPDSSnapshot { fixture in
      try await fixture.insertPDSSnapshot(sequence: 1)
      let query: PostgresQuery
      switch invalid {
      case "cursor": query = "UPDATE wire_ingestion_inbox SET cursor_kind = 'jetstream_v2_seq' WHERE environment = \(fixture.environment)"
      case "eventKind": query = "UPDATE wire_ingestion_inbox SET event_kind = 'commit' WHERE environment = \(fixture.environment)"
      case "operation": query = "UPDATE wire_ingestion_inbox SET operation = 'create' WHERE environment = \(fixture.environment)"
      case "collection": query = "UPDATE wire_ingestion_inbox SET collection = 'app.bsky.feed.post' WHERE environment = \(fixture.environment)"
      case "recordType": query = "UPDATE wire_ingestion_inbox SET payload = jsonb_set(payload, '{snapshot,record,$type}', '\"site.standard.graph.recommend\"'::jsonb) WHERE environment = \(fixture.environment)"
      case "cid": query = "UPDATE wire_ingestion_inbox SET record_cid = 'different-cid' WHERE environment = \(fixture.environment)"
      case "rev": query = "UPDATE wire_ingestion_inbox SET repo_rev = '3m22222222222' WHERE environment = \(fixture.environment)"
      default: query = "UPDATE wire_ingestion_inbox SET repo_rev = NULL WHERE environment = \(fixture.environment)"
      }
      try await fixture.pool.query(query, logger: fixture.logger)
      #expect(try await fixture.apply(sequence: 1) == .terminal)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_items WHERE author_key = \(fixture.repoDID)") == 0)
      #expect(try await fixture.snapshotActorCount() == 0)
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(fixture.environment) AND status = 'dead_letter'
          AND failure_category = 'malformed_event' AND applied_at IS NULL
        """) == 1)
    }
  }

  @Test("an expired snapshot lease cannot create projections")
  func pdsSnapshotRejectsExpiredLease() async throws {
    try await WireRecommendationJournalFixture.runPDSSnapshot { fixture in
      try await fixture.insertPDSSnapshot(sequence: 1)
      let event = try await fixture.claim(sequence: 1)
      try await fixture.pool.query(
        "UPDATE wire_ingestion_inbox SET lease_expires_at = \(fixture.now) WHERE environment = \(fixture.environment)",
        logger: fixture.logger)
      #expect(try await fixture.processor().applyClaimed(event, asOf: fixture.now.addingTimeInterval(60)) == .leaseLost)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_items WHERE author_key = \(fixture.repoDID)") == 0)
    }
  }

  @Test("snapshot recovery respects account inactivity and retained retraction cutoffs",
    arguments: [false, true])
  func pdsSnapshotRespectsAccountFence(_ active: Bool) async throws {
    try await WireRecommendationJournalFixture.runPDSSnapshot { fixture in
      try await fixture.pool.query(
        """
        INSERT INTO wire_recommendation_account_fences
          (environment, repo_did, active, event_time, inactive_through, updated_at)
        VALUES (\(fixture.environment), \(fixture.repoDID), \(active), \(fixture.now.addingTimeInterval(10)),
                \(fixture.now.addingTimeInterval(5)), \(fixture.now))
        """, logger: fixture.logger)
      try await fixture.insertPDSSnapshot(sequence: 1)
      #expect(try await fixture.apply(sequence: 1) == .terminal)
      #expect(try await fixture.scalar(
        "SELECT COUNT(*)::bigint FROM wire_items WHERE author_key = \(fixture.repoDID)") == 0)
      #expect(try await fixture.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_ingestion_inbox WHERE environment = \(fixture.environment)
          AND status = 'dead_letter' AND failure_category = 'snapshot_account_inactive'
        """) == 1)
    }
  }
}

private extension WireRecommendationJournalFixture {
  static func runPDSSnapshot(_ operation: (Self) async throws -> Void) async throws {
    try await run { fixture in
      do {
        try await operation(fixture)
        try await fixture.pool.query("DELETE FROM wire_standard_record_fences WHERE environment = \(fixture.environment)", logger: fixture.logger)
      } catch {
        _ = try? await fixture.pool.query("DELETE FROM wire_standard_record_fences WHERE environment = \(fixture.environment)", logger: fixture.logger)
        throw error
      }
    }
  }

  var snapshotURL: String { "https://\(environment).example.test" }

  func snapshotActorCount() async throws -> Int64 {
    let hash = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8)).hash(repoDID)
    return try await scalar("SELECT COUNT(*)::bigint FROM wire_active_actors WHERE actor_key_hash = \(hash)")
  }

  func insertPDSSnapshot(
    sequence: Int64, collection: String = "site.standard.document", key: String = "first",
    fields: [String: String]? = nil
  ) async throws {
    var record = fields ?? ["url": snapshotURL + "/article", "title": "Authoritative Article"]
    record["$type"] = collection
    let revision = "3m2222222222\(Array("234567abcdefghijklmnopqrstuvwxyz")[Int(sequence) % 32])"
    let cid = "bafy-snapshot-\(sequence)"
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
      "snapshot": ["record": record, "cid": cid, "rev": revision] as [String: Any],
    ]), as: UTF8.self)
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, record_key, record_cid, repo_rev, payload, event_time, next_attempt_at)
      VALUES (\(environment), 'live', \(sequence), 'https://pds.example.test', 'pds_record_snapshot',
              'snapshot', \(repoDID), \(collection), 'update', \(key), \(cid), \(revision),
              \(payload)::jsonb, \(now.addingTimeInterval(Double(sequence))), \(now))
      """, logger: logger)
  }
}
