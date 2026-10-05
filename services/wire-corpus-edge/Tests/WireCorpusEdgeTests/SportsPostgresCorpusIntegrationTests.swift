import SportsCore
import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore
@testable import WireCorpusEdge

@Suite("Sports PostgreSQL Corpus parity", .serialized, .enabled(
  if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
  "Requires an explicitly disposable migrated PostgreSQL database."))
struct SportsPostgresCorpusIntegrationTests {
  @Test("event reference metadata is served without a news generation")
  func catalogIndependentOfNewsGeneration() async throws {
    let logger = Logger(label: "sports-corpus-reference.test")
    let config = try WireCorpusEdgePostgresConfig.make(from: try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"]), maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }; defer { running.cancel() }
    let now = Date()
    let key = UUID().uuidString
    let snapshotID = UUID()
    let team = SportsEntity(id: key + "team", name: "Reference Fixture Team", kind: "team", competitionIDs: [key])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = String(decoding: try encoder.encode(SportsCatalogSnapshot(version: key, generatedAt: now, entities: [team])), as: UTF8.self)
    try await pool.query("UPDATE sports_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE", logger: logger)
    try await pool.query("INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active) VALUES (\(snapshotID),\(key),\(now),\(payload)::jsonb,TRUE)", logger: logger)
    let event = SportsEvent(id: key, competitionID: key, title: "Reference Fixture", startsAt: now, status: "scheduled", homeName: team.name, updatedAt: now)
    let eventPayload = String(decoding: try encoder.encode(event), as: UTF8.self)
    try await pool.query("INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) VALUES (\(key),\(key),\(eventPayload)::jsonb,\(now),\(now.addingTimeInterval(3600)))", logger: logger)
    let response = try await PostgresWireCorpusStore(pool: pool, logger: logger).sportsEvents(now: now, competitionIDs: [], entityIDs: [team.id], global: false)
    #expect(response.map(\.id) == [key])
    #expect(response.first?.entityIDs.contains(team.id) == true)
    let rows = try await pool.query("SELECT version FROM wire_serving.sports_catalog", logger: logger)
    for try await row in rows { #expect(try row.decode(String.self) == key) }
    try await pool.query("DELETE FROM sports_events WHERE event_id=\(key)", logger: logger)
    try await pool.query("DELETE FROM sports_catalog_snapshots WHERE snapshot_id=\(snapshotID)", logger: logger)
  }

  @Test("Hockey interests include child disciplines while named feeds and child follows stay isolated")
  func hockeyDescendantInterests() async throws {
    let logger = Logger(label: "sports-corpus-hockey.test")
    let config = try WireCorpusEdgePostgresConfig.make(from: try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"]), maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }; defer { running.cancel() }
    let now = Date()
    let key = UUID().uuidString
    let snapshotID = UUID()
    let hockey = SportsEntity(id: SportsReviewedCatalog.id("sport:hockey"), name: "Hockey", kind: "sport")
    let ice = SportsEntity(id: SportsReviewedCatalog.id("sport:ice-hockey"), name: "Ice Hockey", kind: "sport", sportID: hockey.id)
    let field = SportsEntity(id: key + "field", name: "Field Hockey", kind: "sport", sportID: hockey.id)
    let winter = SportsEntity(id: SportsReviewedCatalog.id("sport:winter-sports"), name: "Winter Sports", kind: "sport")
    let nhl = SportsEntity(id: key + "nhl", name: "NHL", kind: "competition", sportID: ice.id)
    let fih = SportsEntity(id: key + "fih", name: "FIH", kind: "competition", sportID: field.id)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = String(decoding: try encoder.encode(SportsCatalogSnapshot(version: key, generatedAt: now, entities: [hockey, ice, field, winter, nhl, fih])), as: UTF8.self)
    try await pool.query("UPDATE sports_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE", logger: logger)
    try await pool.query("INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active) VALUES (\(snapshotID),\(key),\(now),\(payload)::jsonb,TRUE)", logger: logger)
    for competition in [nhl.id, fih.id, key + "unrelated"] {
      let event = SportsEvent(id: competition, competitionID: competition, title: "Fixture", startsAt: now.addingTimeInterval(3600), status: "scheduled", updatedAt: now)
      let value = String(decoding: try encoder.encode(event), as: UTF8.self)
      try await pool.query("INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) VALUES (\(competition),\(competition),\(value)::jsonb,\(now),\(now.addingTimeInterval(86400)))", logger: logger)
    }
    let store = PostgresWireCorpusStore(pool: pool, logger: logger)
    #expect(Set(try await store.sportsEvents(now: now, competitionIDs: [], entityIDs: [], global: true, preferredIDs: [hockey.id]).map(\.competitionID)) == Set([nhl.id, fih.id]))
    #expect(try await store.sportsEvents(now: now, competitionIDs: [], entityIDs: [], global: true, preferredIDs: [ice.id]).map(\.competitionID) == [nhl.id])
    #expect(try await store.sportsEvents(now: now, competitionIDs: [], entityIDs: [], global: true, preferredIDs: [winter.id]).map(\.competitionID) == [nhl.id])
    #expect(try await store.sportsEvents(now: now, competitionIDs: [nhl.id], entityIDs: [], global: false, preferredIDs: [hockey.id]).map(\.competitionID) == [nhl.id])
    #expect(try await store.sportsEvents(now: now, competitionIDs: [fih.id], entityIDs: [], global: false, preferredIDs: [ice.id]).isEmpty)
    try await pool.query("DELETE FROM sports_events WHERE event_id=ANY(\([nhl.id, fih.id, key + "unrelated"])::text[])", logger: logger)
    try await pool.query("DELETE FROM sports_catalog_snapshots WHERE snapshot_id=\(snapshotID)", logger: logger)
  }

  @Test("active matches survive pre-limit schedule ordering and future weeks remain available")
  func expandedScheduleOrdering() async throws {
    let logger = Logger(label: "sports-corpus-schedule.test")
    let config = try WireCorpusEdgePostgresConfig.make(from: try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"]), maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }; defer { running.cancel() }
    let now = Date()
    let key = UUID().uuidString
    try await pool.query("""
      INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at)
      SELECT \(key)||n,\(key),jsonb_build_object('id',\(key)||n,'competitionID',\(key),'entityIDs','[]'::jsonb,'title','Upcoming','startsAt',\(now)+n*INTERVAL '1 minute','status','scheduled','updatedAt',\(now)),\(now),\(now.addingTimeInterval(86400)) FROM generate_series(1,600) n
      """, logger: logger)
    let active = SportsEvent(id: key + "active", competitionID: key, title: "Active", startsAt: now.addingTimeInterval(-7200), status: "in-progress", updatedAt: now)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = String(decoding: try encoder.encode(active), as: UTF8.self)
    try await pool.query("INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) VALUES (\(active.id),\(key),\(payload)::jsonb,\(now),\(now.addingTimeInterval(86400)))", logger: logger)
    let store = PostgresWireCorpusStore(pool: pool, logger: logger)
    let response = try await store.sportsEvents(now: now, competitionIDs: [key], entityIDs: [], global: false)
    #expect(response.count == 500)
    #expect(response.first?.id == active.id)
    try await pool.query("DELETE FROM sports_events WHERE competition_id=\(key)", logger: logger)
  }

  @Test("retained pre-zone tables receive reviewed standings places without overwriting provider zones")
  func retainedZones() async throws {
    let logger = Logger(label: "sports-corpus-zones.test")
    let config = try WireCorpusEdgePostgresConfig.make(from: try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"]), maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }; defer { running.cancel() }
    let now = Date()
    let competition = SportsReviewedCatalog.id("competition:efl-championship")
    let providerZone = SportsStandingZone(kind: "qualification", label: "Provider Qualification", sourceURL: "https://www.thesportsdb.com/")
    let table = SportsStandingSnapshot(competitionID: competition, season: "2026-2027", status: "available", updatedAt: now,
      rows: (1...24).map { rank in SportsStandingRow(id: "zone-fixture-" + String(rank), name: "Fixture " + String(rank), rank: rank, zone: rank == 3 ? providerZone : nil) })
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = String(decoding: try encoder.encode(table), as: UTF8.self)
    try await pool.query("INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at) VALUES (\(competition),'2026-2027',\(payload)::jsonb,\(now),\(now.addingTimeInterval(86400)))", logger: logger)
    let tables = try await PostgresWireCorpusStore(pool: pool, logger: logger).sportsStandings(now: now)
    let served = try #require(tables.first { $0.competitionID == competition })
    #expect(served.rows[0].zone?.kind == "promotion")
    #expect(served.rows[2].zone == providerZone)
    #expect(served.rows[7].zone?.kind == "playoff")
    #expect(served.rows[8].zone == nil)
    #expect(served.rows[21].zone == nil)
    #expect(served.rows.map(\.rank) == table.rows.map(\.rank))
    try await pool.query("DELETE FROM sports_standings WHERE competition_id=\(competition) AND season='2026-2027'", logger: logger)
  }

  @Test("Sports presentation views preserve identities and recheck exact language, moderation and deletion")
  func currentPresentationAuthority() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "sports-corpus.test")
    let config = try WireCorpusEdgePostgresConfig.make(from: url, maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let key = UUID().uuidString.lowercased()
    let labeler = "did:example:sports-corpus:\(key)"
    let generation = UUID()
    let now = Date()
    let instrument = SportsEntity(id: "sp_\(key)", name: "Fixture Team", kind: "team", competitionIDs: [key], memberships: [SportsMembership(entityID: "fixture-competition", validFrom: now.addingTimeInterval(-3600), validUntil: now.addingTimeInterval(3600), season: "2026")])
    let item = WireFeedItem(itemID: key, canonicalURL: "https://example.com/\(key)", representativeURI: nil,
      title: "Fixture earnings", summary: nil, publishedAt: now, thumbnailURL: nil,
      source: WireItemSource(name: "Fixture", domain: "example.com"), reasons: [], provenance: [])
    let candidate = SportsRankCandidate(item: item, analysis: SportsArticleAnalysis(eligible: true,
      materiality: "earnings", associations: [SportsAssociation(entityID: instrument.id,
        confidence: 1, evidence: ["structured-metadata"], prominence: 0)], sportIDs: [], competitionIDs: []), baseScore: 100)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = String(decoding: try encoder.encode([candidate]), as: UTF8.self)
    let instrumentPayload = String(decoding: try encoder.encode(instrument), as: UTF8.self)
    let catalogPayload = String(decoding: try JSONEncoder().encode(SportsCatalogSnapshot(version: "fixture", generatedAt: now, entities: [instrument])), as: UTF8.self)
    let store = PostgresWireCorpusStore(pool: pool, logger: logger)
    do {
      try await pool.query("""
        INSERT INTO wire_label_refresh_state
          (source_did, endpoint_host, last_attempted_at, last_successful_at, target_count, label_count, is_current)
        VALUES (\(labeler), 'labels.example', \(now), \(now), 0, 0, TRUE)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_items (canonical_key, canonical_url, source_domain, source_name, title,
          first_seen_at, last_seen_at, expires_at, language_code)
        VALUES (\(key), \(item.canonicalURL), 'example.com', 'Fixture', 'Fixture earnings',
          \(now), \(now), \(now.addingTimeInterval(3600)), 'qx')
        """, logger: logger)
      try await pool.query("UPDATE sports_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE", logger: logger)
      try await pool.query("INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active) VALUES (\(generation),'fixture',\(now),\(catalogPayload)::jsonb,TRUE)", logger: logger)
      try await pool.query("""
        INSERT INTO sports_entities (entity_id, payload, updated_at)
        VALUES (\(instrument.id), \(instrumentPayload)::jsonb, \(now))
        """, logger: logger)
      try await pool.query("""
        INSERT INTO sports_generations (generation_id, source_generation_id, language, algorithm_version,
          generated_at, expires_at, payload, is_active)
        VALUES (\(generation), \(generation), 'qx', 'sports-v1', \(now), \(now.addingTimeInterval(3600)), \(payload)::jsonb, TRUE)
        """, logger: logger)
      let event = SportsEvent(id: key, competitionID: key, entityIDs: [], title: "Fixture match", startsAt: now, status: "scheduled", homeName: instrument.name, updatedAt: now)
      let eventPayload = String(decoding: try encoder.encode(event), as: UTF8.self)
      try await pool.query("INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) VALUES (\(key),\(key),\(eventPayload)::jsonb,\(now),\(now.addingTimeInterval(3600)))", logger: logger)
      let table = SportsStandingSnapshot(competitionID: key, season: "2026", status: "available", updatedAt: now, rows: [.init(id: instrument.id, name: instrument.name, rank: 1, points: "12.5")])
      let tablePayload = String(decoding: try encoder.encode(table), as: UTF8.self)
      try await pool.query("INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at) VALUES (\(key),'2026',\(tablePayload)::jsonb,\(now),\(now.addingTimeInterval(3600)))", logger: logger)
      try await pool.query("""
        INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at)
        SELECT \(key)||'unrelated-standing'||n,'2026',jsonb_set(\(tablePayload)::jsonb,'{competitionID}',to_jsonb(\(key)||'unrelated-standing'||n)),\(now.addingTimeInterval(1)),\(now.addingTimeInterval(86400)) FROM generate_series(1,101) n
        """, logger: logger)
      let schedule = SportsScheduleStatus(competitionID: key, status: "available", updatedAt: now)
      let schedulePayload = String(decoding: try encoder.encode(schedule), as: UTF8.self)
      try await pool.query("INSERT INTO sports_schedule_status(competition_id,payload,updated_at,expires_at) VALUES (\(key),\(schedulePayload)::jsonb,\(now),\(now.addingTimeInterval(3600)))", logger: logger)
      #expect(try await store.sportsEvents(now: now, competitionIDs: [], entityIDs: [instrument.id], global: false).map(\.id) == [key])
      #expect(try await store.sportsEvents(now: now, competitionIDs: [], entityIDs: [], global: true, teamIDs: [instrument.id]).map(\.id) == [key])
      try await pool.query("""
        INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at)
        SELECT \(key)||'unrelated'||n,'unrelated',jsonb_build_object('id',\(key)||'unrelated'||n,'competitionID','unrelated','entityIDs','[]'::jsonb,'title','Unrelated','startsAt',\(now)+n*INTERVAL '1 second','status','scheduled','updatedAt',\(now)),\(now),\(now.addingTimeInterval(3600)) FROM generate_series(1,600) n
        """, logger: logger)
      #expect(try await store.sportsEvents(now: now, competitionIDs: [], entityIDs: [], global: true, preferredIDs: [instrument.id]).map(\.id) == [key])
      #expect(try await store.sportsEvents(now: now, competitionIDs: ["other"], entityIDs: [], global: false, preferredIDs: [instrument.id]).isEmpty)
      try await pool.query("DELETE FROM sports_events WHERE event_id LIKE \(key + "unrelated%")", logger: logger)
      let newTeam = SportsEntity(id: key + "newteam", name: "New Fixture Team", kind: "team", competitionIDs: [key])
      let transferAt = now.addingTimeInterval(86400)
      let person = SportsEntity(id: key + "athlete", name: "Fixture Athlete", kind: "athlete", memberships: [.init(entityID: instrument.id, validFrom: now.addingTimeInterval(-3*86400), validUntil: transferAt), .init(entityID: newTeam.id, validFrom: transferAt)])
      let transferCatalog = String(decoding: try encoder.encode([instrument, newTeam, person]), as: UTF8.self)
      try await pool.query("UPDATE sports_catalog_snapshots SET payload=jsonb_set(payload,'{entities}',\(transferCatalog)::jsonb) WHERE snapshot_id=\(generation)", logger: logger)
      let dated = [SportsEvent(id: key + "past-old", competitionID: key, title: "Past old team", startsAt: now.addingTimeInterval(-86400), status: "finished", homeName: instrument.name, updatedAt: now), SportsEvent(id: key + "future-old", competitionID: key, title: "Future old team", startsAt: now.addingTimeInterval(2*86400), status: "scheduled", homeName: instrument.name, updatedAt: now), SportsEvent(id: key + "future-new", competitionID: key, title: "Future new team", startsAt: now.addingTimeInterval(2*86400), status: "scheduled", homeName: newTeam.name, updatedAt: now)]
      for datedEvent in dated {
        let value = String(decoding: try encoder.encode(datedEvent), as: UTF8.self)
        try await pool.query("INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) VALUES (\(datedEvent.id),\(key),\(value)::jsonb,\(now),\(now.addingTimeInterval(3600)))", logger: logger)
      }
      let transferred = try await store.sportsEvents(now: now, competitionIDs: [], entityIDs: [], global: true, preferredIDs: [person.id])
      #expect(Set(transferred.map(\.id)) == Set([key, key + "past-old", key + "future-new"]))
      try await pool.query("DELETE FROM sports_events WHERE event_id=ANY(\(dated.map(\.id))::text[])", logger: logger)
      try await pool.query("UPDATE sports_catalog_snapshots SET payload=\(catalogPayload)::jsonb WHERE snapshot_id=\(generation)", logger: logger)


      #expect(try await store.sportsEvents(now: now, competitionIDs: ["other"], entityIDs: [], global: false, teamIDs: [instrument.id]).isEmpty)
      #expect(try await store.sportsEvents(now: now, competitionIDs: [], entityIDs: [], global: true, teamIDs: []).isEmpty)

      #expect(try await store.sportsEvents(now: now, competitionIDs: ["other"], entityIDs: [], global: false).isEmpty)
      #expect(try await store.sportsStandings(now: now).first { $0.competitionID == key } == nil)
      #expect(try await store.sportsStandings(now: now, preferredIDs: [instrument.id]).first?.rows.first?.points == "12.5")
      #expect(try await store.sportsStandings(now: now, preferredIDs: [instrument.id]).map(\.competitionID) == [key])
      #expect(try await store.sportsStandings(now: now, preferredIDs: ["unrelated"]).isEmpty)
      try await pool.query("DELETE FROM sports_standings WHERE competition_id LIKE \(key + "unrelated-standing%")", logger: logger)
      #expect(try await store.sportsSchedules(now: now).first { $0.competitionID == key }?.status == "available")
      #expect(try await store.sportsStandings(now: now.addingTimeInterval(3601)).first { $0.competitionID == key } == nil)
      let first = try await store.sports(language: "qx", now: now)
      #expect(first.candidates.count == 1)
      #expect(first.entities == [instrument])
      try await pool.query("UPDATE sports_generations SET payload=jsonb_set(payload, '{0,analysis,resolverVersion}', '\"sports-resolver-v1\"'::jsonb) WHERE generation_id=\(generation)", logger: logger)
      await #expect(throws: WireCorpusEdgeStoreError.unavailable) { _ = try await store.sports(language: "qx", now: now) }
      try await pool.query("UPDATE sports_generations SET payload=\(payload)::jsonb WHERE generation_id=\(generation)", logger: logger)
      try await pool.query("UPDATE sports_generations SET payload=jsonb_set(payload, '{0,analysis,associations,0,resolverVersion}', '\"sports-resolver-v1\"'::jsonb) WHERE generation_id=\(generation)", logger: logger)
      await #expect(throws: WireCorpusEdgeStoreError.unavailable) { _ = try await store.sports(language: "qx", now: now) }
      try await pool.query("UPDATE sports_generations SET payload=\(payload)::jsonb WHERE generation_id=\(generation)", logger: logger)
      await #expect(throws: WireCorpusEdgeStoreError.unavailable) {
        _ = try await store.sports(language: "qy", now: now)
      }
      try await pool.query("UPDATE wire_items SET language_code = 'qy' WHERE canonical_key = \(key)", logger: logger)
      #expect(try await store.sports(language: "qx", now: now).candidates.isEmpty)
      try await pool.query("UPDATE wire_items SET language_code = 'qx' WHERE canonical_key = \(key)", logger: logger)
      try await pool.query("""
        INSERT INTO wire_labels (canonical_key, label_key, label_value, source, applied_at, expires_at)
        VALUES (\(key), 'block', 'block', 'test', \(now), \(now.addingTimeInterval(3600)))
        """, logger: logger)
      #expect(try await store.sports(language: "qx", now: now).candidates.isEmpty)
      try await pool.query("DELETE FROM wire_labels WHERE canonical_key = \(key)", logger: logger)
      #expect(try await store.sports(language: "qx", now: now).candidates.count == 1)
      try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
      #expect(try await store.sports(language: "qx", now: now).candidates.isEmpty)
    } catch {
      try? await cleanup(pool: pool, logger: logger, key: key, labeler: labeler, generation: generation, instrument: instrument.id)
      throw error
    }
    try await cleanup(pool: pool, logger: logger, key: key, labeler: labeler, generation: generation, instrument: instrument.id)
  }

  private func cleanup(pool: PostgresClient, logger: Logger, key: String, labeler: String, generation: UUID, instrument: String) async throws {
    try await pool.query("DELETE FROM sports_events WHERE event_id=\(key)", logger: logger)
    try await pool.query("DELETE FROM sports_standings WHERE competition_id=\(key)", logger: logger)
    try await pool.query("DELETE FROM sports_schedule_status WHERE competition_id=\(key)", logger: logger)
    try await pool.query("DELETE FROM sports_catalog_snapshots WHERE snapshot_id=\(generation)", logger: logger)
    try await pool.query("DELETE FROM sports_generations WHERE generation_id = \(generation)", logger: logger)
    try await pool.query("DELETE FROM sports_entities WHERE entity_id = \(instrument)", logger: logger)
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    try await pool.query("DELETE FROM wire_label_refresh_state WHERE source_did = \(labeler)", logger: logger)
  }
}
