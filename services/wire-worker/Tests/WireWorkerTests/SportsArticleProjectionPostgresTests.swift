import Foundation
import Logging
import PostgresNIO
import SportsCore
import Testing
@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("Sports independently projects the canonical corpus, bounds batches and rejects stale or retracted evidence")
  func sportsCanonicalProjection() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "sports-projection.integration")
    let pool = PostgresClient(configuration: try PostgresWireConfig.make(from: url, logger: logger), backgroundLogger: logger)
    let running = Task { await pool.run() }; defer { running.cancel() }
    let prefix = "sports-worker-" + UUID().uuidString.lowercased(), snapshotID = UUID(), sourceID = UUID(), secondSourceID = UUID(), oldResolverSourceID = UUID()
    let rollbackFunction = "sports_rollback_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let now = Date()
    var previousID: UUID?
    for try await row in try await pool.query("SELECT snapshot_id FROM sports_catalog_snapshots WHERE is_active=TRUE", logger: logger) { previousID = try row.decode(UUID.self) }
    let snapshot = SportsCatalogSnapshot(version: SportsReviewedCatalog.version + ":fixture:" + prefix, generatedAt: now, entities: SportsReviewedCatalog.entities)
    let payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    try await pool.query("UPDATE sports_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE", logger: logger)
    try await pool.query("INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active) VALUES (\(snapshotID),\(snapshot.version),\(now),\(payload)::jsonb,TRUE)", logger: logger)
    do {
      try await pool.query("""
        INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,
          first_seen_at,last_seen_at,expires_at,eligible,target_kind,source_confidence,provenance,language_code)
        SELECT \(prefix)||'-'||n,'https://sports-fixture.test/'||\(prefix)||'/'||n,'sports-fixture.test','Fixture',
          CASE WHEN n=26 THEN 'NBA basketball betting odds and predictions' ELSE 'NBA championship reporting for fixture '||n END,
          \(now),\(now),CASE WHEN n=28 THEN \(now.addingTimeInterval(-1)) ELSE \(now.addingTimeInterval(3600)) END,
          n<>27,'standard_site_document',0.9,'["standard_site"]'::jsonb,\(prefix)
        FROM generate_series(0,28) n
        """, logger: logger)
      let projector = PostgresSportsArticleProjector(pool: pool, logger: logger)
      // Deployment order cannot stamp the new catalog revision on older identities.
      let oldVersion = "sports-reviewed-v2:fixture:" + prefix
      let oldSnapshot = SportsCatalogSnapshot(version: oldVersion, generatedAt: now, entities: snapshot.entities)
      let oldPayload = String(decoding: try JSONEncoder().encode(oldSnapshot), as: UTF8.self)
      try await pool.query("UPDATE sports_catalog_snapshots SET version=\(oldVersion),payload=\(oldPayload)::jsonb WHERE snapshot_id=\(snapshotID)", logger: logger)
      #expect(try await projector.project(asOf: now) == 0)
      for try await row in try await pool.query("SELECT count(*) FROM sports_article_analysis WHERE canonical_key LIKE \(prefix + "%")", logger: logger) { #expect(try row.decode(Int.self) == 0) }
      try await pool.query("UPDATE sports_catalog_snapshots SET version=\(snapshot.version),payload=\(payload)::jsonb WHERE snapshot_id=\(snapshotID)", logger: logger)
      // A failure after both windows have advanced rolls back their writes and cursor.
      try await pool.query("INSERT INTO sports_article_analysis(canonical_key,source_fingerprint,catalog_revision,resolver_version,payload,analyzed_at,expires_at) VALUES (\(prefix + "-28"),'fixture','fixture',\(SportsResolver.version),'{}'::jsonb,\(now),\(now.addingTimeInterval(-1)))", logger: logger)
      try await pool.query(PostgresQuery(unsafeSQL: "CREATE FUNCTION \(rollbackFunction)() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'sports fixture rollback'; END; $$"), logger: logger)
      try await pool.query(PostgresQuery(unsafeSQL: "CREATE TRIGGER \(rollbackFunction) BEFORE DELETE ON sports_article_analysis FOR EACH ROW WHEN (OLD.canonical_key='\(prefix)-28') EXECUTE FUNCTION \(rollbackFunction)()"), logger: logger)
      await #expect(throws: (any Error).self) { try await projector.project(asOf: now) }
      for try await row in try await pool.query("SELECT count(*) FROM sports_article_analysis WHERE canonical_key LIKE \(prefix + "%")", logger: logger) { #expect(try row.decode(Int.self) == 1) }
      try await pool.query(PostgresQuery(unsafeSQL: "DROP FUNCTION \(rollbackFunction)() CASCADE"), logger: logger)
      // Other replicas skip the held cycle lock rather than waiting or writing.
      try await pool.withTransaction(logger: logger) { connection in
        try await connection.query("SELECT pg_advisory_xact_lock(hashtextextended(\(PostgresSportsArticleProjector.cycleLockKey),0))", logger: logger)
        #expect(try await projector.project(asOf: now) == 0)
      }
      #expect(try await projector.project(asOf: now) == 25)
      #expect(try await projector.project(asOf: now) == 2)
      #expect(try await projector.project(asOf: now) == 0)
      let catalog = try #require(try await PostgresSportsCatalogReader.load(pool: pool, logger: logger))
      let materializer = PostgresSportsMaterializer(pool: pool, logger: logger, authority: nil, environment: ["SPORTS_FEED_MODE": "api"])
      try await pool.query("UPDATE sports_article_analysis SET resolver_version='sports-resolver-v1' WHERE canonical_key=\(prefix + "-0")", logger: logger)
      try await materializer.materialize(sourceID: oldResolverSourceID, language: prefix, catalog: catalog, asOf: now)
      for try await row in try await pool.query("SELECT jsonb_array_length(payload) FROM sports_generations WHERE source_generation_id=\(oldResolverSourceID)", logger: logger) { #expect(try row.decode(Int.self) == 26) }
      #expect(try await projector.project(asOf: now.addingTimeInterval(0.5)) == 1)
      for try await row in try await pool.query("SELECT resolver_version FROM sports_article_analysis WHERE canonical_key=\(prefix + "-0")", logger: logger) { #expect(try row.decode(String.self) == SportsResolver.version) }
      try await materializer.materialize(sourceID: sourceID, language: prefix, catalog: catalog, asOf: now)
      var initial: [Int] = []
      for try await row in try await pool.query("SELECT jsonb_array_length(payload) FROM sports_generations WHERE source_generation_id=\(sourceID)", logger: logger) { initial.append(try row.decode(Int.self)) }
      #expect(initial == [26])
      // A catalog/resolver rollout leaves one fresh analysis and many old ones.
      // Materialization revalidates the bounded old evidence rather than shrinking
      // the committed generation to the one newly projected article.
      try await pool.query("UPDATE sports_article_analysis SET catalog_revision='prior-catalog',resolver_version='sports-resolver-v8' WHERE canonical_key LIKE \(prefix + "%") AND canonical_key<>\(prefix + "-0")", logger: logger)
      let rolloutSourceID = UUID()
      try await materializer.materialize(sourceID: rolloutSourceID, language: prefix, catalog: catalog, asOf: now.addingTimeInterval(0.75))
      for try await row in try await pool.query("SELECT jsonb_array_length(payload),NOT EXISTS(SELECT 1 FROM jsonb_array_elements(payload) candidate WHERE candidate->'analysis'->>'resolverVersion'<>\(SportsResolver.version)) FROM sports_generations WHERE source_generation_id=\(rolloutSourceID)", logger: logger) {
        let (count, current) = try row.decode((Int, Bool).self)
        #expect(count == 26); #expect(current)
      }
      try await pool.query("DELETE FROM sports_generations WHERE source_generation_id=\(rolloutSourceID)", logger: logger)
      // Corpus serving contains every catalog identity, including entities not mentioned by these articles.
      for try await row in try await pool.query("SELECT jsonb_array_length(entities) FROM wire_serving.sports_generations WHERE language=\(prefix)", logger: logger) { #expect(try row.decode(Int.self) == snapshot.entities.count) }
      // Changed source evidence is rejected before the next projection pass.
      try await pool.query("UPDATE wire_items SET title='How to prepare chicken stock for soup' WHERE canonical_key=\(prefix + "-0")", logger: logger)
      try await pool.query("UPDATE wire_items SET eligible=FALSE WHERE canonical_key=\(prefix + "-1")", logger: logger)
      try await materializer.materialize(sourceID: secondSourceID, language: prefix, catalog: catalog, asOf: now.addingTimeInterval(1))
      var changed: [Int] = []
      for try await row in try await pool.query("SELECT jsonb_array_length(payload) FROM sports_generations WHERE source_generation_id=\(secondSourceID)", logger: logger) { changed.append(try row.decode(Int.self)) }
      #expect(changed == [24])
      let rolloutProjected = try await projector.project(asOf: now.addingTimeInterval(2))
      #expect(rolloutProjected > 0 && rolloutProjected <= PostgresSportsArticleProjector.batchLimit)
      for try await row in try await pool.query("SELECT payload->>'eligible' FROM sports_article_analysis WHERE canonical_key=\(prefix + "-0")", logger: logger) { #expect(try row.decode(String.self) == "false") }
      // No key and no review maps means neither event polling nor roster requests are attempted.
      let refresh = PostgresSportsProviderRefresh(pool: pool, logger: logger, authority: nil, environment: [:])
      try await refresh.run(asOf: now)
    } catch {
      try await pool.query(PostgresQuery(unsafeSQL: "DROP FUNCTION IF EXISTS \(rollbackFunction)() CASCADE"), logger: logger)
      try await cleanupSportsFixture(pool: pool, logger: logger, prefix: prefix, snapshotID: snapshotID, previousID: previousID, sources: [sourceID, secondSourceID, oldResolverSourceID]); throw error
    }
    try await cleanupSportsFixture(pool: pool, logger: logger, prefix: prefix, snapshotID: snapshotID, previousID: previousID, sources: [sourceID, secondSourceID, oldResolverSourceID])
  }
}

private func cleanupSportsFixture(pool: PostgresClient, logger: Logger, prefix: String, snapshotID: UUID, previousID: UUID?, sources: [UUID]) async throws {
  try await pool.query("DELETE FROM sports_generations WHERE source_generation_id=ANY(\(sources)::uuid[])", logger: logger)
  try await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
  try await pool.query("DELETE FROM sports_catalog_snapshots WHERE snapshot_id=\(snapshotID)", logger: logger)
  if let previousID { try await pool.query("UPDATE sports_catalog_snapshots SET is_active=TRUE WHERE snapshot_id=\(previousID)", logger: logger) }
}
