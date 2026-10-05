import AsyncHTTPClient
import Foundation
import GatewayCore
import Logging
import PostgresNIO
import SportsCore
import Testing
import ThinAppViewCore
import WireCore
@testable import AppView

@Suite("Sports PostgreSQL serving", .serialized, .enabled(if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
  "Requires explicitly disposable migrated PostgreSQL database"))
struct SportsPostgresServingIntegrationTests {
  @Test func immutableContextModerationAndProviderOutage() async throws {
    let logger = Logger(label: "sports-postgres.test")
    var configuration = try makePostgresConfig(from: try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"]), logger: logger)
    configuration.options.maximumConnections = 2
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let run = Task { await pool.run() }; defer { run.cancel() }
    await Task.yield()
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    let namespace = UUID().uuidString.lowercased(); let viewer = "did:example:sports:" + namespace
    let now = Date(); let sourceID = UUID(); let secret = String(repeating: "s", count: 32)
    let team = SportsEntity(id: "sp_" + namespace, name: "Fixture United", kind: "team", memberships: [SportsMembership(entityID: "fixture-competition", validFrom: now.addingTimeInterval(-3600), validUntil: now.addingTimeInterval(3600), season: "2026")])
    let school = SportsEntity(id: team.id + "-school", name: "Fixture University", kind: "school")
    let items = (0..<3).map { i in WireFeedItem(itemID: "sports-\(namespace)-\(i)", canonicalURL: "https://example.com/\(namespace)/\(i)", representativeURI: nil,
      title: i == 2 ? "Global championship record" : "Fixture United wins championship \(i)", summary: nil, publishedAt: now,
      thumbnailURL: nil, source: WireItemSource(name: "Fixture", domain: "example.com"), reasons: [], provenance: []) }
    let candidates = items.enumerated().map { i, item in SportsRankCandidate(item: item,
      analysis: SportsArticleAnalysis(eligible: true, materiality: "championship", associations: i == 2 ? [] :
        [SportsAssociation(entityID: team.id, confidence: 1, evidence: ["structured-metadata"], prominence: 0)], sportIDs: [], competitionIDs: []), baseScore: Double(100 - i * 10), majorGlobal: i == 2) }
    let source = SportsSourceGeneration(generationId: sourceID.uuidString.lowercased(), generatedAt: now,
      expiresAt: now.addingTimeInterval(48 * 3600), language: "en", candidates: candidates, entities: [team, school])
    let wire = SportsServingWireStub(items: items, now: now)
    let corpus = SportsServingCorpusStub(source: source)
    let store = try PostgresSportsFeedStore(pool: pool, logger: logger,
      config: SportsDiscoveryConfig(mode: .visible, cursorSecret: secret, eventsEnabled: false), wire: wire,
      selections: SportsSelectionProjection(pool: pool, repo: ATProtoAuthenticatedRepoClient(httpClient: http, plcURL: "https://plc.directory", logger: logger), logger: logger), transport: corpus)
    try await pool.query("INSERT INTO sports_selection_sync(viewer_did,synced_at) VALUES (\(viewer),\(now))", logger: logger)
    do {
      let first = try await store.page(cursor: nil, limit: 1, language: "en", viewerDID: viewer, refresh: false, now: now)
      #expect(first.items.first?.entities.first?.memberships?.first?.season == "2026")
      #expect(try await store.entities(query: school.name, now: now).isEmpty)
      let requestsBeforeCatalog = await corpus.requests
      let catalog = try await store.availability(now: now)
      #expect(await corpus.requests == requestsBeforeCatalog)
      #expect(catalog.available)
      #expect(catalog.entities.contains { $0.id == school.id })
      #expect(!catalog.feeds.contains { $0.entityIDs.contains(school.id) })
      let cursor = try #require(first.cursor)
      #expect(try await store.page(cursor: nil, limit: 1, language: "en", viewerDID: viewer, refresh: false, now: now).generationId == first.generationId)
      await #expect(throws: WireServingError.invalidCursor) { _ = try await store.page(cursor: cursor, limit: 1, language: "fr", viewerDID: viewer, refresh: false, now: now) }
      await #expect(throws: WireServingError.invalidCursor) { _ = try await store.page(cursor: cursor, limit: 1, language: "en", viewerDID: viewer, refresh: false, now: now, region: "outside-us") }
      await #expect(throws: WireServingError.invalidCursor) { _ = try await store.page(cursor: cursor, limit: 1, language: "en", viewerDID: nil, refresh: false, now: now) }
      let named = try await store.page(cursor: nil, limit: 50, language: "en", viewerDID: viewer, refresh: false, now: now, feed: "entity:" + team.id)
      #expect(named.items.count == 2)
      await wire.suppress(items[1].itemID, viewer: viewer)
      let next = try await store.page(cursor: cursor, limit: 50, language: "en", viewerDID: viewer, refresh: false, now: now)
      #expect(!next.items.contains { $0.story.itemID == items[1].itemID })
      await corpus.fail()
      let retained = try await store.page(cursor: nil, limit: 50, language: "en", viewerDID: viewer, refresh: false, now: now)
      #expect(retained.generationId == first.generationId)
      // Even a snapshot retaining the current preference revision must reject obsolete eligibility.
      try await pool.query("UPDATE sports_personalized_snapshots SET payload=jsonb_set(payload, '{0,analysis,resolverVersion}', '\"sports-resolver-v1\"'::jsonb) WHERE snapshot_id=\(try #require(UUID(uuidString: first.generationId)))", logger: logger)
      await #expect(throws: WireServingError.cursorExpired) { _ = try await store.page(cursor: cursor, limit: 50, language: "en", viewerDID: viewer, refresh: false, now: now) }
      try await pool.query("UPDATE sports_generations SET payload=jsonb_set(payload, '{0,analysis,resolverVersion}', '\"sports-resolver-v1\"'::jsonb) WHERE generation_id=\(sourceID)", logger: logger)
      await corpus.useObsoleteSource()
      let revalidated = try await store.page(cursor: nil, limit: 50, language: "en", viewerDID: viewer, refresh: false, now: now)
      #expect(revalidated.source == .simplifiedFallback)
      #expect(revalidated.generationId != first.generationId)
      #expect(revalidated.items.allSatisfy { $0.associations.allSatisfy { $0.resolverVersion == SportsResolver.version } })
      await #expect(throws: WireServingError.cursorExpired) { _ = try await store.page(cursor: cursor, limit: 50, language: "en", viewerDID: viewer, refresh: false, now: now.addingTimeInterval(48 * 3600 + 1)) }
      #expect(try await store.events(feed: "sports", now: now).events.isEmpty)
    } catch {
      try? await clean(pool, logger, viewer, team.id, sourceID)
      try? await http.shutdown(); throw error
    }
    try await clean(pool, logger, viewer, team.id, sourceID); try await http.shutdown()
  }
  @Test func sharedStandingsAndSchedulesStayScopedWhenOtherLeaguesFillTheCache() async throws {
    let logger = Logger(label: "sports-context-postgres.test")
    let configuration = try makePostgresConfig(from: try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"]), logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let run = Task { await pool.run() }; defer { run.cancel() }
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    let prefix = "sp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let now = Date()
    let fieldHockey = SportsReviewedCatalog.id("sport:field-hockey")
    let competition = SportsEntity(id: prefix + "league", name: "Fixture League", kind: "competition", sportID: fieldHockey)
    let team = SportsEntity(id: prefix + "team", name: "Fixture Club", kind: "team", sportID: fieldHockey, competitionIDs: [competition.id])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let hockeySports = SportsReviewedCatalog.entities.filter { ["sport:hockey", "sport:field-hockey", "sport:ice-hockey"].map(SportsReviewedCatalog.id).contains($0.id) }
    for entity in [competition, team] + hockeySports {
      let payload = String(decoding: try encoder.encode(entity), as: UTF8.self)
      try await pool.query("INSERT INTO sports_entities(entity_id,payload,updated_at) VALUES (\(entity.id),\(payload)::jsonb,\(now))", logger: logger)
    }
    let event = SportsEvent(id: prefix + "event", competitionID: competition.id, entityIDs: [], title: "Fixture game", startsAt: now.addingTimeInterval(600), status: "scheduled", homeName: team.name, updatedAt: now)
    let eventPayload = String(decoding: try encoder.encode(event), as: UTF8.self)
    try await pool.query("INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) VALUES (\(event.id),\(competition.id),\(eventPayload)::jsonb,\(now),\(now.addingTimeInterval(86400)))", logger: logger)
    // A global top-500 prefilter used to hide this named club's fixture.
    try await pool.query("""
      INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at)
      SELECT \(prefix)||'-other-'||n,'unrelated',jsonb_build_object('id',\(prefix)||'-other-'||n,'competitionID','unrelated','entityIDs','[]'::jsonb,'title','Unrelated','startsAt',\(now),'status','scheduled','updatedAt',\(now)),\(now),\(now.addingTimeInterval(86400)) FROM generate_series(1,600) n
      """, logger: logger)
    let table = SportsStandingSnapshot(competitionID: competition.id, season: "2026", status: "available", updatedAt: now, rows: [.init(id: team.id, entityID: team.id, name: team.name, rank: 7, points: "12.5"), .init(id: prefix + "other", entityID: prefix + "other", name: "Unfollowed Team", rank: 1, points: "42")])
    let tablePayload = String(decoding: try encoder.encode(table), as: UTF8.self)
    try await pool.query("INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at) VALUES (\(competition.id),'2026',\(tablePayload)::jsonb,\(now),\(now.addingTimeInterval(86400)))", logger: logger)
    try await pool.query("""
      INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at)
      SELECT \(prefix)||'unrelated-standing'||n,'2026',jsonb_set(\(tablePayload)::jsonb,'{competitionID}',to_jsonb(\(prefix)||'unrelated-standing'||n)),\(now.addingTimeInterval(1)),\(now.addingTimeInterval(86400)) FROM generate_series(1,101) n
      """, logger: logger)
    // Cached rows written before provider reference mapping must reconcile by unique competition/name.
    try await pool.query("UPDATE sports_standings SET payload=payload #- '{rows,0,entityID}' WHERE competition_id=\(competition.id)", logger: logger)
    let store = try PostgresSportsFeedStore(pool: pool, logger: logger, config: SportsDiscoveryConfig(mode: .visible, cursorSecret: String(repeating: "s", count: 32), eventsEnabled: true), wire: SportsServingWireStub(items: [], now: now), selections: SportsSelectionProjection(pool: pool, repo: ATProtoAuthenticatedRepoClient(httpClient: http, plcURL: "https://plc.directory", logger: logger), logger: logger))
    let response = try await store.events(feed: "entity:" + team.id, now: now)
    let umbrella = try await store.events(feed: "entity:" + SportsReviewedCatalog.id("sport:hockey"), now: now)
    #expect(umbrella.events.contains { $0.id == event.id })
    #expect(umbrella.standings.contains { $0.competitionID == competition.id })
    let iceOnly = try await store.events(feed: "entity:" + SportsReviewedCatalog.id("sport:ice-hockey"), now: now)
    #expect(!iceOnly.events.contains { $0.id == event.id })
    #expect(!iceOnly.standings.contains { $0.competitionID == competition.id })
    let umbrellaFollow = try await store.events(feed: "sports", now: now, preferredIDs: [SportsReviewedCatalog.id("sport:hockey")])
    #expect(umbrellaFollow.events.contains { $0.id == event.id })
    #expect(umbrellaFollow.standings.contains { $0.competitionID == competition.id })
    #expect(response.events.map(\.id) == [event.id])
    let teamScope = try await store.events(feed: "sports", now: now, teamIDs: [team.id])
    #expect(teamScope.events.map(\.id) == [event.id])
    let followedScope = try await store.events(feed: "sports", now: now, preferredIDs: [team.id], timeZone: TimeZone(identifier: "America/New_York")!)
    #expect(followedScope.events.map(\.id) == [event.id])
    #expect(!followedScope.eventsLimited)
    #expect(followedScope.preferredIDs == [team.id])
    #expect(followedScope.standings.map(\.competitionID) == [competition.id])
    #expect(try await store.events(feed: "sports", now: now, preferredIDs: [competition.id]).standings.map(\.competitionID) == [competition.id])
    try await pool.query("DELETE FROM sports_standings WHERE competition_id LIKE \(prefix + "unrelated-standing%")", logger: logger)
    #expect(followedScope.timeZone == "America/New_York")
    let newTeam = SportsEntity(id: prefix + "newteam", name: "New Fixture Club", kind: "team", competitionIDs: [competition.id])
    let transferAt = now.addingTimeInterval(86400)
    let person = SportsEntity(id: prefix + "athlete", name: "Fixture Athlete", kind: "athlete", memberships: [.init(entityID: team.id, validFrom: now.addingTimeInterval(-3*86400), validUntil: transferAt), .init(entityID: newTeam.id, validFrom: transferAt)])
    for entity in [newTeam, person] {
      let value = String(decoding: try encoder.encode(entity), as: UTF8.self)
      try await pool.query("INSERT INTO sports_entities(entity_id,payload,updated_at) VALUES (\(entity.id),\(value)::jsonb,\(now))", logger: logger)
    }
    let dated = [SportsEvent(id: prefix + "past-old", competitionID: competition.id, title: "Past old team", startsAt: now.addingTimeInterval(-86400), status: "finished", homeName: team.name, updatedAt: now), SportsEvent(id: prefix + "future-old", competitionID: competition.id, title: "Future old team", startsAt: now.addingTimeInterval(2*86400), status: "scheduled", homeName: team.name, updatedAt: now), SportsEvent(id: prefix + "future-new", competitionID: competition.id, title: "Future new team", startsAt: now.addingTimeInterval(2*86400), status: "scheduled", homeName: newTeam.name, updatedAt: now)]
    for datedEvent in dated {
      let value = String(decoding: try encoder.encode(datedEvent), as: UTF8.self)
      try await pool.query("INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) VALUES (\(datedEvent.id),\(competition.id),\(value)::jsonb,\(now),\(now.addingTimeInterval(86400)))", logger: logger)
    }
    let transferred = try await store.events(feed: "sports", now: now, preferredIDs: [person.id])
    #expect(Set(transferred.events.map(\.id)) == Set([event.id, prefix + "past-old", prefix + "future-new"]))
    try await pool.query("DELETE FROM sports_events WHERE event_id=ANY(\(dated.map(\.id))::text[])", logger: logger)
    try await pool.query("DELETE FROM sports_entities WHERE entity_id=ANY(\([newTeam.id, person.id])::text[])", logger: logger)

    #expect(try await store.events(feed: "entity:" + team.id, now: now, preferredIDs: [competition.id]).events.map(\.id) == [event.id])

    #expect(teamScope.standings.first?.rows.map(\.entityID) == [team.id, prefix + "other"])
    #expect(teamScope.standings.first?.rows.map(\.rank) == [7, 1])
    #expect(followedScope.standings.first?.rows.map(\.rank) == [7, 1])
    #expect(teamScope.standings.first?.rows.first?.rank == 7)
    #expect(try await store.events(feed: "sports", now: now, teamIDs: []).events.isEmpty)
    #expect(try await store.events(feed: "sports", now: now, teamIDs: []).standings.isEmpty)
    await #expect(throws: WireServingError.invalidCursor) { _ = try await store.events(feed: "sports", now: now, teamIDs: [competition.id]) }

    #expect(response.standings.first?.rows.first?.points == "12.5")
    #expect(response.schedulesStatus == "available")
    #expect(!response.standings[0].degraded)
    let stale = try await store.events(feed: "entity:" + team.id, now: now.addingTimeInterval(3601))
    #expect(stale.standings[0].degraded)
    #expect(stale.standings[0].rows == table.rows)
    let outage = SportsServingCorpusStub(source: .init(generationId: UUID().uuidString, generatedAt: now, expiresAt: now.addingTimeInterval(86400), language: "en", candidates: []))
    await outage.fail()
    let outageStore = try PostgresSportsFeedStore(pool: pool, logger: logger, config: SportsDiscoveryConfig(mode: .visible, cursorSecret: String(repeating: "s", count: 32), eventsEnabled: true), wire: SportsServingWireStub(items: [], now: now), selections: SportsSelectionProjection(pool: pool, repo: ATProtoAuthenticatedRepoClient(httpClient: http, plcURL: "https://plc.directory", logger: logger), logger: logger), transport: outage)
    let retained = try await outageStore.events(feed: "entity:" + team.id, now: now)
    #expect(retained.events.map(\.id) == [event.id])
    #expect(retained.standings[0].degraded)
    #expect(retained.standings[0].rows == table.rows)
    try await pool.query("DELETE FROM sports_events WHERE event_id LIKE \(prefix + "%")", logger: logger)
    let empty = SportsScheduleStatus(competitionID: competition.id, status: "empty", updatedAt: now)
    let emptyPayload = String(decoding: try encoder.encode(empty), as: UTF8.self)
    try await pool.query("INSERT INTO sports_schedule_status(competition_id,payload,updated_at,expires_at) VALUES (\(competition.id),\(emptyPayload)::jsonb,\(now),\(now.addingTimeInterval(86400)))", logger: logger)
    #expect(try await store.events(feed: "entity:" + team.id, now: now).schedulesStatus == "empty")
    try await pool.query("DELETE FROM sports_schedule_status WHERE competition_id=\(competition.id)", logger: logger)
    #expect(try await store.events(feed: "entity:" + team.id, now: now).schedulesStatus == "unavailable")
    try await pool.query("DELETE FROM sports_standings WHERE competition_id=\(competition.id)", logger: logger)
    try await pool.query("DELETE FROM sports_entities WHERE entity_id=ANY(\([competition.id,team.id] + hockeySports.map(\.id))::text[])", logger: logger)
    try await http.shutdown()
  }

  @Test func cachedLegacyZonesHydrateBeforeFollowedTeamFiltering() async throws {
    let logger = Logger(label: "sports-zones-postgres.test")
    let config = try makePostgresConfig(from: try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"]), logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }; defer { running.cancel() }
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    let now = Date()
    let key = UUID().uuidString
    let competitionID = SportsReviewedCatalog.id("competition:premier-league")
    let club = SportsEntity(id: "sp_" + key, name: "Fixture Club " + key, kind: "team", competitionIDs: [competitionID])
    let competition = SportsEntity(id: competitionID, name: "Premier League", kind: "competition")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    for entity in [competition, club] {
      let payload = String(decoding: try encoder.encode(entity), as: UTF8.self)
      try await pool.query("INSERT INTO sports_entities(entity_id,payload,updated_at) VALUES (\(entity.id),\(payload)::jsonb,\(now)) ON CONFLICT(entity_id) DO NOTHING", logger: logger)
    }
    let providerZone = SportsStandingZone(kind: "playoff", label: "Provider Relegation Play-Off", sourceURL: "https://www.thesportsdb.com/")
    let table = SportsStandingSnapshot(competitionID: competitionID, season: "2026-2027", status: "available", updatedAt: now,
      rows: (1...20).map { rank in SportsStandingRow(id: key + String(rank), name: rank == 18 ? club.name : "Fixture " + String(rank), rank: rank, zone: rank == 19 ? providerZone : nil) })
    let payload = String(decoding: try encoder.encode(table), as: UTF8.self)
    try await pool.query("INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at) VALUES (\(competitionID),'2026-2027',\(payload)::jsonb,\(now),\(now.addingTimeInterval(86400)))", logger: logger)
    let store = try PostgresSportsFeedStore(pool: pool, logger: logger, config: SportsDiscoveryConfig(mode: .visible, cursorSecret: String(repeating: "s", count: 32), eventsEnabled: true), wire: SportsServingWireStub(items: [], now: now), selections: SportsSelectionProjection(pool: pool, repo: ATProtoAuthenticatedRepoClient(httpClient: http, plcURL: "https://plc.directory", logger: logger), logger: logger))
    let global = try await store.events(feed: "sports", now: now)
    let served = try #require(global.standings.first { $0.competitionID == competitionID })
    #expect(served.rows[17].zone?.kind == "relegation")
    #expect(served.rows[18].zone == providerZone)
    #expect(served.rows[16].zone == nil)
    let scoped = try await store.events(feed: "sports", now: now, teamIDs: [club.id])
    #expect(scoped.standings.first?.rows.count == 20)
    #expect(scoped.standings.first?.rows.map(\.rank) == Array(1...20))
    #expect(scoped.standings.first?.rows[17].rank == 18)
    #expect(scoped.standings.first?.rows[17].zone?.kind == "relegation")
    #expect(scoped.standings.first?.rows[17].entityID == club.id)
    try await pool.query("DELETE FROM sports_standings WHERE competition_id=\(competitionID) AND season='2026-2027'", logger: logger)
    try await pool.query("DELETE FROM sports_entities WHERE entity_id=ANY(\([club.id, competitionID])::text[])", logger: logger)
    try await http.shutdown()
  }

  @Test func expandedScheduleIncludesFutureWeeksAndPrioritizesActiveGames() async throws {
    let logger = Logger(label: "sports-expanded-schedule.test")
    let config = try makePostgresConfig(from: try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"]), logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }; defer { running.cancel() }
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    // Keep the final game's two-hour offset inside the viewer's current UTC day.
    // Wall-clock midnight otherwise changes the expected activity tier.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
    let key = "sp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let competition = SportsEntity(id: key + "league", name: "Fixture League", kind: "competition")
    let club = SportsEntity(id: key + "team", name: "Fixture Club", kind: "team", competitionIDs: [competition.id])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    for entity in [competition, club] {
      let payload = String(decoding: try encoder.encode(entity), as: UTF8.self)
      try await pool.query("INSERT INTO sports_entities(entity_id,payload,updated_at) VALUES (\(entity.id),\(payload)::jsonb,\(now))", logger: logger)
    }
    var events = (1...60).map { day in SportsEvent(id: key + String(day), competitionID: competition.id, entityIDs: [club.id], title: "Future Game", startsAt: now.addingTimeInterval(Double(day) * 86400), status: "scheduled", updatedAt: now) }
    events.append(SportsEvent(id: key + "active", competitionID: competition.id, entityIDs: [club.id], title: "Active Game", startsAt: now.addingTimeInterval(-3600), status: "in-progress", updatedAt: now))
    events.append(SportsEvent(id: key + "recent", competitionID: competition.id, entityIDs: [club.id], title: "Recent Game", startsAt: now.addingTimeInterval(-7200), status: "finished", updatedAt: now))
    let payload = String(decoding: try encoder.encode(events), as: UTF8.self)
    try await pool.query("INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) SELECT value->>'id',value->>'competitionID',value,\(now),\(now.addingTimeInterval(86400)) FROM jsonb_array_elements(\(payload)::jsonb) value", logger: logger)
    let store = try PostgresSportsFeedStore(pool: pool, logger: logger, config: SportsDiscoveryConfig(mode: .visible, cursorSecret: String(repeating: "s", count: 32), eventsEnabled: true), wire: SportsServingWireStub(items: [], now: now), selections: SportsSelectionProjection(pool: pool, repo: ATProtoAuthenticatedRepoClient(httpClient: http, plcURL: "https://plc.directory", logger: logger), logger: logger))
    let response = try await store.events(feed: "entity:" + club.id, now: now)
    #expect(response.events.count == 62)
    #expect(response.events.prefix(2).map(\.id) == [key + "active", key + "recent"])
    #expect(response.events.contains { $0.startsAt > now.addingTimeInterval(59 * 86400) })
    #expect(response.bracketSources.isEmpty)
    #expect(!response.eventsLimited)
    try await pool.query("""
      INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at)
      SELECT \(key)||'extra'||n,\(competition.id),jsonb_build_object('id',\(key)||'extra'||n,'competitionID',\(competition.id),'entityIDs',jsonb_build_array(\(club.id)),'title','Upcoming','startsAt',\(now)+n*INTERVAL '1 minute','status','scheduled','updatedAt',\(now)),\(now),\(now.addingTimeInterval(86400)) FROM generate_series(1,600) n
      """, logger: logger)
    let limited = try await store.events(feed: "entity:" + club.id, now: now)
    #expect(limited.events.count == 500)
    #expect(limited.eventsLimited)
    #expect(limited.events.prefix(2).map(\.id) == [key + "active", key + "recent"])

    try await pool.query("DELETE FROM sports_events WHERE competition_id=\(competition.id)", logger: logger)
    try await pool.query("DELETE FROM sports_entities WHERE entity_id=ANY(\([club.id, competition.id])::text[])", logger: logger)
    try await http.shutdown()
  }

  private func clean(_ pool: PostgresClient, _ logger: Logger, _ viewer: String, _ id: String, _ source: UUID) async throws {
    try await pool.query("DELETE FROM sports_generations WHERE generation_id=\(source)", logger: logger)
    try await pool.query("DELETE FROM sports_selection_sync WHERE viewer_did=\(viewer)", logger: logger)
    try await pool.query("DELETE FROM sports_entities WHERE entity_id=ANY(\([id, id + "-school"])::text[])", logger: logger)
  }
}
private actor SportsServingWireStub: WireFeedStore {
  private var items: [String: WireFeedItem]
  private let order: [String]
  private var suppressed: [String: Set<String>] = [:]
  private let now: Date
  init(items: [WireFeedItem], now: Date) { self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) }); self.order = items.map(\.itemID); self.now = now }
  func suppress(_ id: String, viewer: String) { suppressed[viewer, default: []].insert(id) }
  func remove(_ id: String) { items.removeValue(forKey: id) }
  func replace(_ item: WireFeedItem) { items[item.itemID] = item }
  func getItem(itemId: String, viewerDid: String?) async throws -> WireItemDetail? {
    if let viewerDid, suppressed[viewerDid]?.contains(itemId) == true { return nil }
    return items[itemId].map { WireItemDetail(item: $0) }
  }
  func getFeed(cursor: String?, limit: Int, language: String?, viewerDid: String?, now: Date) async throws -> WirePage {
    WirePage(generationID: UUID().uuidString.lowercased(), generatedAt: now, language: language ?? "und", cursor: nil,
      source: .simplifiedFallback, degraded: true, items: order.compactMap { items[$0] })
  }
  func getCatalog(now: Date) async throws -> WireFeedCatalog {
    WireFeedCatalog(enabled: false, available: false, supportedLanguages: [])
  }
  func getEdition(language: String?, region: WireViewerRegion?, viewerDid: String?, now: Date) async throws -> WireEdition { throw WireServingError.unavailable }
}

private actor SportsServingCorpusStub: WireCorpusTransport {
  var source: SportsSourceGeneration
  var unavailable = false
  var requests = 0
  init(source: SportsSourceGeneration) { self.source = source }
  func fail() { unavailable = true }
  func useObsoleteSource() {
    unavailable = false
    let old = source.candidates.map { candidate in
      SportsRankCandidate(item: candidate.item, analysis: SportsArticleAnalysis(eligible: true,
        materiality: candidate.analysis.materiality, associations: candidate.analysis.associations,
        sportIDs: candidate.analysis.sportIDs, competitionIDs: candidate.analysis.competitionIDs,
        resolverVersion: "sports-resolver-v1"), baseScore: candidate.baseScore, majorGlobal: candidate.majorGlobal)
    }
    source = SportsSourceGeneration(generationId: source.generationId, generatedAt: source.generatedAt,
      expiresAt: source.expiresAt, language: source.language, candidates: old, entities: source.entities)
  }
  func get(target: String) async throws -> WireCorpusTransportResponse {
    requests += 1
    guard !unavailable else { throw WireServingError.unavailable }
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return WireCorpusTransportResponse(statusCode: 200, contractVersion: 3, body: try encoder.encode(source))
  }
}
