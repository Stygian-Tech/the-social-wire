import FinanceCore
import Foundation
import Logging
import PostgresNIO
import Testing
@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("Finance projects each canonical article once, bounds batches and invalidates source and catalog revisions")
  func financeArticleProjectionCache() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "finance-article-projection.integration")
    let pool = PostgresClient(configuration: try PostgresWireConfig.make(from: url, logger: logger), backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    defer { runTask.cancel() }
    let suffix = UUID().uuidString.lowercased()
    let prefix = "finance-projection-" + suffix
    let snapshotID = UUID()
    let sourceID = UUID()
    let secondSourceID = UUID()
    let now = Date()
    var oldVersion: String?
    let previous = try await pool.query("SELECT version FROM finance_catalog_snapshots WHERE is_active=TRUE", logger: logger)
    for try await row in previous { oldVersion = try row.decode(String.self) }
    let snapshot = FinanceCatalogSnapshot(version: prefix, generatedAt: now, instruments: FinanceReviewedCatalog.instruments)
    let payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    try await pool.query("UPDATE finance_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE", logger: logger)
    try await pool.query("""
      INSERT INTO finance_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active)
      VALUES (\(snapshotID),\(prefix),\(now),\(payload)::jsonb,TRUE)
      """, logger: logger)
    do {
      // A discovered universe larger than the reader's 150-row bound must not
      // make the publication guard hash a different, unbounded universe.
      var instruments: [FinanceInstrument] = []
      for n in 0..<151 {
        let ordinal = String(n)
        let instrumentID = prefix + "-instrument-" + ordinal
        let name = "Projection Fixture Company " + ordinal
        let symbol = "FIX" + ordinal
        let providerID = "BBG" + suffix + ordinal
        instruments.append(FinanceInstrument(id: instrumentID, name: name,
          symbol: symbol, kind: "Common Stock", providerID: providerID))
      }
      let discoveredPayload = String(decoding: try JSONEncoder().encode(instruments), as: UTF8.self)
      try await pool.query("""
        INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)
        SELECT instrument->>'id',instrument->>'providerID',instrument,\(now)
        FROM jsonb_array_elements(\(discoveredPayload)::jsonb) instrument
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,
          first_seen_at,last_seen_at,expires_at,eligible,target_kind,source_confidence,provenance,language_code)
        SELECT \(prefix)||'-'||n, 'https://finance-fixture.test/'||\(suffix)||'/'||n,
          'finance-fixture.test','Fixture',CASE WHEN n=26 THEN 'Stock rises after routine price target chatter' ELSE 'Inflation and economic growth' END,\(now),\(now),
          CASE WHEN n=28 THEN \(now.addingTimeInterval(-1)) ELSE \(now.addingTimeInterval(3600)) END,n<>27,'standard_site_document',0.9,'["standard_site"]'::jsonb,\(prefix)
        FROM generate_series(0,28) n
        """, logger: logger)
      // No Wire generation or social rollup exists: Finance must admit quality macro articles independently.
      let projector = PostgresFinanceArticleProjector(pool: pool, logger: logger)
      #expect(try await projector.project(asOf: now) == 25)
      #expect(try await projector.project(asOf: now) == 2)
      #expect(try await projector.project(asOf: now) == 0)
      let acceptedRows = try await pool.query("SELECT count(*) FROM finance_article_analysis WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
      for try await row in acceptedRows { #expect(try row.decode(Int64.self) == 27) }
      let initialCatalog = try #require(try await PostgresFinanceCatalogReader.load(pool: pool, logger: logger))
      let initialMaterializer = PostgresFinanceMaterializer(pool: pool, logger: logger, authority: nil,
        environment: ["FINANCE_FEED_MODE":"api","FINANCE_CATALOG_RIGHTS_CONFIRMED":"true"])
      try await initialMaterializer.materialize(sourceID: secondSourceID, language: prefix, catalog: initialCatalog, asOf: now)
      let initial = try await pool.query("SELECT jsonb_array_length(payload) FROM finance_generations WHERE source_generation_id=\(secondSourceID)", logger: logger)
      for try await row in initial { #expect(try row.decode(Int.self) == 26) }
      // High-confidence macro news serves with no Wire generation/signals; routine price chatter does not.
      // A resolver upgrade must invalidate unchanged v2 evidence independently
      // of source fingerprints and the catalog revision, for both true and false positives.
      try await pool.query("UPDATE wire_items SET title='How to make chicken stock for soup' WHERE canonical_key=\(prefix + "-1")", logger: logger)
      try await pool.query("""
        UPDATE finance_article_analysis analysis SET resolver_version='finance-resolver-v2',
          source_fingerprint=md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text),
          payload=jsonb_set(jsonb_set(analysis.payload,'{resolverVersion}','"finance-resolver-v2"'::jsonb),'{eligible}','true'::jsonb)
        FROM wire_items item WHERE analysis.canonical_key=item.canonical_key
          AND item.canonical_key=ANY(\([prefix + "-0",prefix + "-1"])::text[])
        """, logger: logger)
      #expect(try await projector.project(asOf: now.addingTimeInterval(0.5)) == 2)
      let upgraded = try await pool.query("""
        SELECT analysis.canonical_key,analysis.resolver_version,(analysis.payload->>'eligible')::boolean,
          analysis.source_fingerprint=md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text)
        FROM finance_article_analysis analysis JOIN wire_items item USING(canonical_key)
        WHERE analysis.canonical_key=ANY(\([prefix + "-0",prefix + "-1"])::text[])
        ORDER BY analysis.canonical_key
        """, logger: logger)
      var upgradedCount = 0
      for try await row in upgraded {
        let (key,revision,eligible,unchangedSource) = try row.decode((String,String,Bool,Bool).self)
        #expect(revision == FinanceResolver.version)
        #expect(unchangedSource)
        #expect(eligible == (key == prefix + "-0"))
        upgradedCount += 1
      }
      #expect(upgradedCount == 2)
      // Source changes immediately stop Coordinator from accepting the old analysis.
      try await pool.query("UPDATE wire_items SET title='Central bank changes interest rates' WHERE canonical_key=\(prefix + "-0")", logger: logger)
      #expect(try await projector.project(asOf: now.addingTimeInterval(1)) == 1)
      // Reviewed catalog revision invalidates every cached analysis without provider calls.
      let next = FinanceCatalogSnapshot(version: prefix + "-next", generatedAt: now, instruments: snapshot.instruments)
      let nextPayload = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
      try await pool.query("UPDATE finance_catalog_snapshots SET version=\(next.version),payload=\(nextPayload)::jsonb WHERE snapshot_id=\(snapshotID)", logger: logger)
      var refreshed2 = 0
      for _ in 0..<3 {
        let batch = try await projector.project(asOf: now.addingTimeInterval(2))
        #expect(batch <= 25); refreshed2 += batch
      }
      #expect(refreshed2 == 27)
      let catalog = try #require(try await PostgresFinanceCatalogReader.load(pool: pool, logger: logger))
      // Make all cached evidence stale: Coordinator must preserve the prior generation and perform no inline resolution.
      try await pool.query("UPDATE wire_items SET title='New inflation report' WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
      let materializer = PostgresFinanceMaterializer(pool: pool, logger: logger, authority: nil,
        environment: ["FINANCE_FEED_MODE":"api","FINANCE_CATALOG_RIGHTS_CONFIRMED":"true"])
      try await materializer.materialize(sourceID: sourceID, language: prefix, catalog: catalog, asOf: now.addingTimeInterval(3))
      let missing = try await pool.query("SELECT COUNT(*) FROM finance_generations WHERE source_generation_id=\(sourceID)", logger: logger)
      for try await row in missing { #expect(try row.decode(Int64.self) == 0) }
      var refreshed3 = 0
      for _ in 0..<3 {
        let batch = try await projector.project(asOf: now.addingTimeInterval(3))
        #expect(batch <= 25); refreshed3 += batch
      }
      #expect(refreshed3 == 27)
      try await materializer.materialize(sourceID: sourceID, language: prefix, catalog: catalog, asOf: now.addingTimeInterval(4))
      let committed = try await pool.query("SELECT jsonb_array_length(payload) FROM finance_generations WHERE source_generation_id=\(sourceID)", logger: logger)
      var counts: [Int] = []
      for try await row in committed { counts.append(try row.decode(Int.self)) }
      #expect(counts == [27])
      // A full zero-result head window cannot starve an older macro story.
      try await pool.query("""
        INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,
          first_seen_at,last_seen_at,expires_at,eligible,target_kind,source_confidence,provenance,language_code,updated_at)
        SELECT \(prefix)||'-sweep-'||n,'https://finance-fixture.test/'||\(suffix)||'/sweep/'||n,
          'finance-fixture.test','Fixture',CASE WHEN n=1001 THEN 'Inflation and economic growth' ELSE 'Football championship match highlights' END,
          \(now),\(now),\(now.addingTimeInterval(3600)),TRUE,'standard_site_document',0.9,
          '["standard_site"]'::jsonb,\(prefix),\(now)-make_interval(secs=>n+1)
        FROM generate_series(0,1001) n
        """, logger: logger)
      let sweeping = PostgresFinanceArticleProjector(pool: pool, logger: logger)
      #expect(try await sweeping.project(asOf: now.addingTimeInterval(5)) == 0)
      #expect(try await sweeping.project(asOf: now.addingTimeInterval(5)) == 1)
      // New head news is analyzed immediately even while background progress is old.
      try await pool.query("""
        INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,
          first_seen_at,last_seen_at,expires_at,eligible,target_kind,source_confidence,provenance,language_code,updated_at)
        VALUES (\(prefix + "-new-head"),\("https://finance-fixture.test/" + suffix + "/new"),
          'finance-fixture.test','Fixture','New inflation report',\(now),\(now),\(now.addingTimeInterval(3600)),
          TRUE,'standard_site_document',0.9,'["standard_site"]'::jsonb,\(prefix),\(now.addingTimeInterval(5)))
        """, logger: logger)
      #expect(try await sweeping.project(asOf: now.addingTimeInterval(6)) == 1)

    } catch {
      try await cleanupFinanceProjection(pool: pool, logger: logger, prefix: prefix, sources: [sourceID,secondSourceID], snapshotID: snapshotID, oldVersion: oldVersion)
      throw error
    }
    try await cleanupFinanceProjection(pool: pool, logger: logger, prefix: prefix, sources: [sourceID,secondSourceID], snapshotID: snapshotID, oldVersion: oldVersion)
  }
}

private func cleanupFinanceProjection(pool: PostgresClient, logger: Logger, prefix: String, sources: [UUID], snapshotID: UUID, oldVersion: String?) async throws {
  try await pool.query("DELETE FROM finance_generations WHERE source_generation_id=ANY(\(sources)::uuid[])", logger: logger)
  try await pool.query("DELETE FROM wire_rank_generations WHERE generation_id=ANY(\(sources)::uuid[])", logger: logger)
  try await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
  try await pool.query("DELETE FROM finance_catalog_snapshots WHERE snapshot_id=\(snapshotID)", logger: logger)
  try await pool.query("DELETE FROM finance_instruments WHERE instrument_id LIKE \(prefix + "-instrument-%")", logger: logger)
  if let oldVersion { try await pool.query("UPDATE finance_catalog_snapshots SET is_active=TRUE WHERE version=\(oldVersion)", logger: logger) }
}
