import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import PostgresNIO
import SportsCore
import Testing
@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("Reviewed roster refresh preserves identities, closes absent memberships and keeps failed snapshots")
  func sportsProviderSnapshotLifecycle() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "sports-provider.integration")
    let pool = PostgresClient(configuration: try PostgresWireConfig.make(from: url, logger: logger), backgroundLogger: logger)
    let running = Task { await pool.run() }; defer { running.cancel() }
    let prefix = "sports-provider-" + UUID().uuidString.lowercased()
    let competition = SportsEntity(id: SportsIdentity.entityID(seed: prefix + "-competition"), name: "NCAA Women's Basketball", kind: "competition", sportID: SportsReviewedCatalog.id("sport:basketball"), groupPath: ["NCAA", "Division I", "Women's Basketball"])
    let team = SportsEntity(id: SportsIdentity.entityID(seed: prefix + "-team"), name: "Fixture Women's Basketball", kind: "ncaa-team", sportID: competition.sportID, competitionIDs: [competition.id], groupPath: ["NCAA", "Division I", "Women's Basketball", "Fixture Conference"])
    let now = Date(), snapshotID = UUID()
    var previousID: UUID?, ownedSnapshots: [UUID] = [snapshotID], ownedEntities = [competition.id, team.id]
    for try await row in try await pool.query("SELECT snapshot_id FROM sports_catalog_snapshots WHERE is_active=TRUE", logger: logger) { previousID = try row.decode(UUID.self) }
    let initial = SportsCatalogSnapshot(version: prefix, generatedAt: now, entities: [competition, team])
    let payload = String(decoding: try JSONEncoder().encode(initial), as: UTF8.self)
    try await pool.query("UPDATE sports_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE", logger: logger)
    try await pool.query("INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active) VALUES (\(snapshotID),\(prefix),\(now),\(payload)::jsonb,TRUE)", logger: logger)
    let articleKey = prefix + "-article"
    try await pool.query("""
      INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,
        first_seen_at,last_seen_at,expires_at,eligible,target_kind,source_confidence,provenance,language_code)
      VALUES (\(articleKey),\("https://sports-provider-fixture.test/" + prefix),'sports-provider-fixture.test','Fixture',
        'Fixture Women''s Basketball wins NCAA championship',\(now),\(now),\(now.addingTimeInterval(3600)),TRUE,
        'standard_site_document',0.9,'["standard_site"]'::jsonb,\(prefix))
      """, logger: logger)
    try await pool.query("""
      INSERT INTO sports_article_analysis(canonical_key,source_fingerprint,catalog_revision,resolver_version,payload,analyzed_at,expires_at)
      SELECT canonical_key,md5(jsonb_build_array(title,summary,source_domain)::text),\(initial.version),\(SportsResolver.version),
        '{"eligible":true,"materiality":"championship","associations":[],"sportIDs":[],"competitionIDs":[],"resolverVersion":"fixture"}'::jsonb,
        \(now),\(now.addingTimeInterval(3600)) FROM wire_items WHERE canonical_key=\(articleKey)
      """, logger: logger)
    func active() async throws -> SportsCatalogSnapshot {
      let result = try #require(try await PostgresSportsCatalogReader.load(pool: pool, logger: logger))
      for try await row in try await pool.query("SELECT snapshot_id FROM sports_catalog_snapshots WHERE is_active=TRUE", logger: logger) { ownedSnapshots.append(try row.decode(UUID.self)) }
      return result.snapshot
    }
    func cleanup() async throws {
      try await pool.query("DELETE FROM wire_items WHERE canonical_key=\(articleKey)", logger: logger)
      try await pool.query("DELETE FROM sports_catalog_snapshots WHERE snapshot_id=ANY(\(ownedSnapshots)::uuid[])", logger: logger)
      try await pool.query("DELETE FROM sports_entities WHERE entity_id=ANY(\(ownedEntities)::text[])", logger: logger)
      try await pool.query("DELETE FROM sports_provider_refresh WHERE resource_key=ANY(\(["reference:" + competition.id, SportsProviderRefreshPolicy.key("reference", competitionID: competition.id), "events:" + competition.id, SportsProviderRefreshPolicy.key("events", competitionID: competition.id), "roster:" + team.id])::text[])", logger: logger)
      if let previousID { try await pool.query("UPDATE sports_catalog_snapshots SET is_active=TRUE WHERE snapshot_id=\(previousID)", logger: logger) }
    }
    do {
      let fixture = SportsProviderTransportFixture()
      let adapter = TheSportsDBAdapter(apiKey: "fixture") { request in try await fixture.response(request) }
      let mappings = String(decoding: try JSONEncoder().encode([competition.id: "1"]), as: UTF8.self)
      let environment = ["THESPORTSDB_API_KEY": "fixture", "SPORTS_PROVIDER_RIGHTS_CONFIRMED": "true", "SPORTS_REVIEWED_COMPETITIONS": mappings]
      let denied = PostgresSportsProviderRefresh(pool: pool, logger: logger, authority: nil, environment: [:], adapter: adapter)
      try await denied.run(asOf: now)
      #expect(await fixture.requests == 0)
      let refresh = PostgresSportsProviderRefresh(pool: pool, logger: logger, authority: nil, environment: environment, adapter: adapter)
      try await refresh.run(asOf: now)
      let mapped = try await active()
      // Reference metadata changes keep old analysis instead of scanning/deleting
      // the entire article corpus inside the Coordinator activation transaction.
      var retainedRevision: String?
      for try await row in try await pool.query("SELECT catalog_revision FROM sports_article_analysis WHERE canonical_key=\(articleKey)", logger: logger) {
        retainedRevision = try row.decode(String.self)
      }
      #expect(retainedRevision == initial.version)
      let projector = PostgresSportsArticleProjector(pool: pool, logger: logger)
      let reanalyzed = try await projector.project(asOf: now.addingTimeInterval(0.5))
      #expect(reanalyzed > 0 && reanalyzed <= PostgresSportsArticleProjector.batchLimit)
      var rebuiltRevision: String?
      var rebuiltResolver: String?
      for try await row in try await pool.query("SELECT catalog_revision,resolver_version FROM sports_article_analysis WHERE canonical_key=\(articleKey)", logger: logger) {
        let (revision,resolver) = try row.decode((String,String).self)
        rebuiltRevision = revision; rebuiltResolver = resolver
      }
      #expect(rebuiltRevision == mapped.version)
      #expect(rebuiltResolver == SportsResolver.version)
      #expect(mapped.entities.first { $0.id == team.id }?.providerIDs["thesportsdb"] == "2")
      #expect(mapped.entities.first { $0.id == team.id }?.groupPath == team.groupPath)
      #expect(mapped.entities.first { $0.id == team.id }?.abbreviation == "FIX")
      #expect(mapped.entities.first { $0.id == competition.id }?.groupPath == competition.groupPath)
      try await refresh.run(asOf: now.addingTimeInterval(1))
      let roster = try await active()
      let person = try #require(roster.entities.first { $0.kind == "athlete" })
      ownedEntities.append(person.id)
      #expect(person.memberships?.first?.entityID == team.id)
      try await refresh.run(asOf: now.addingTimeInterval(86402))
      let unchanged = try await active()
      #expect(unchanged.version == roster.version)
      try await refresh.run(asOf: now.addingTimeInterval(86403))
      let departed = try await active()
      let samePerson = try #require(departed.entities.first { $0.id == person.id })
      #expect(samePerson.memberships?.first?.validUntil == now.addingTimeInterval(86403))
      #expect(await fixture.scheduleRequests == 0)
      let failing = TheSportsDBAdapter(apiKey: "fixture") { _ in (Data("invalid".utf8), 200) }
      let outage = PostgresSportsProviderRefresh(pool: pool, logger: logger, authority: nil, environment: environment, adapter: failing)
      await #expect(throws: (any Error).self) { try await outage.run(asOf: now.addingTimeInterval(172805)) }
      #expect(try await active().version == departed.version)
      let failureAt = now.addingTimeInterval(172805)
      let claimKey = SportsProviderRefreshPolicy.key("reference", competitionID: competition.id)
      var failedClaim: Date?
      for try await row in try await pool.query("SELECT requested_at FROM sports_provider_refresh WHERE resource_key=\(claimKey)", logger: logger) { failedClaim = try row.decode(Date.self) }
      let retryClaim = try #require(failedClaim)
      #expect(abs(retryClaim.timeIntervalSince(SportsProviderRefreshPolicy.failedClaim(asOf: failureAt, interval: 86400))) < 0.001)
      #expect(!SportsProviderRefreshPolicy.isDue(key: claimKey, interval: 86400, requested: [claimKey: retryClaim], asOf: failureAt.addingTimeInterval(299)))
      #expect(SportsProviderRefreshPolicy.isDue(key: claimKey, interval: 86400, requested: [claimKey: retryClaim], asOf: failureAt.addingTimeInterval(300)))
    } catch { try await cleanup(); throw error }
    try await cleanup()
  }
}

private actor SportsProviderTransportFixture {
  var requests = 0
  var scheduleRequests = 0
  private var rosterRequests = 0
  func response(_ request: URLRequest) throws -> (Data, Int) {
    requests += 1
    let path = request.url!.path
    if path.contains("schedule") { scheduleRequests += 1 }
    let response: String
    if path.contains("list/teams") { response = "{\"list\":[{\"idTeam\":\"2\",\"strTeam\":\"Fixture Women's Basketball\",\"strTeamShort\":\"FIX\"}]}" }
    else {
      rosterRequests += 1
      response = rosterRequests == 1 ? "{\"list\":[{\"idPlayer\":\"3\",\"strPlayer\":\"Fixture Athlete\"}]}" : "{\"list\":[]}"
    }
    return (Data(response.utf8), 200)
  }
}
