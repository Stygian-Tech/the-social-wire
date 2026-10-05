import SportsCore
import Crypto
import Foundation
import Logging
import PostgresNIO
import WireCore

actor PostgresSportsFeedStore {
  private let pool: PostgresClient
  private let logger: Logger
  private let config: SportsDiscoveryConfig
  private let codec: SportsCursorCodec
  private let hasher: WireActorHasher
  private let wire: any WireFeedStore
  private let selections: SportsSelectionProjection
  private let transport: (any WireCorpusTransport)?
  private let retention: SportsSnapshotRetention
  private var importedCatalogGeneration: String?

  init(pool: PostgresClient, logger: Logger, config: SportsDiscoveryConfig,
    wire: any WireFeedStore, selections: SportsSelectionProjection, transport: (any WireCorpusTransport)? = nil) throws {
    guard let secret = config.cursorSecret else { throw WireServingError.unavailable }
    self.pool = pool; self.logger = logger; self.config = config; self.wire = wire
    self.selections = selections; self.transport = transport
    retention = SportsSnapshotRetention(pool: pool, logger: logger)
    codec = try SportsCursorCodec(secret: secret)
    hasher = try WireActorHasher(secret: Data(secret.utf8))
  }

  func availability(now: Date) async throws -> SportsFeedAvailability {
    let catalog = try await loadCatalog()
    // Navigation metadata must not fetch/import all ranked candidates from Corpus.
    // A committed, permitted generation establishes availability independently.
    var available = false
    if config.mode.canServeAPI {
      let rows = try await pool.query("""
        SELECT EXISTS(SELECT 1 FROM sports_generations WHERE language='en' AND expires_at>\(now)
          AND payload->0->'analysis'->>'resolverVersion'=\(SportsResolver.version))
        """, logger: logger)
      for try await row in rows { available = try row.decode(Bool.self) }
    }
    return SportsFeedAvailability(enabled: config.mode == .visible, available: available,
      eventsEnabled: config.eventsEnabled, feeds: SportsNamedFeeds.catalog(entities: catalog), entities: catalog,
      version: Self.catalogRevision(catalog))
  }

  func entities(query: String, now: Date) async throws -> [SportsEntity] {
    guard config.mode.canServeAPI else { throw WireServingError.unavailable }
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty, q.count <= 200 else { throw WireServingError.invalidCursor }
    return Array(try await loadCatalog().filter { SportsNamedFeeds.isSelectable($0) && ($0.id == q || $0.name.localizedCaseInsensitiveContains(q)
      || $0.aliases.contains(where: { $0.localizedCaseInsensitiveContains(q) })) }.prefix(50))
  }

  func events(feed: String, now: Date, teamIDs: [String]? = nil, preferredIDs: [String]? = nil, timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!, timeZoneName: String? = nil) async throws -> SportsEventsResponse {
    guard config.mode.canServeAPI else { throw WireServingError.unavailable }
    guard config.eventsEnabled else { return SportsEventsResponse(events: [], updatedAt: nil, degraded: false) }
    let catalog = try await loadCatalog()
    guard let definition = SportsNamedFeeds.catalog(entities: catalog).first(where: { $0.id == feed }) else {
      throw WireServingError.invalidCursor
    }
    let requestedTeams = try SportsEventTeamFilter.validate(teamIDs, catalog: catalog)
    let preferences = try SportsEventTeamFilter.preferred(preferredIDs, catalog: catalog)
    let personalPreferences = catalog.filter { preferences.contains($0.id) && ["team", "ncaa-team", "national-side", "athlete", "driver"].contains($0.kind) }
    let directPreferences = personalPreferences.map(\.id)
    let memberships = SportsEventPreferenceMembership.bindings(preferredIDs: preferences, catalog: catalog)
    let membershipEncoder = JSONEncoder(); membershipEncoder.dateEncodingStrategy = .iso8601
    let membershipBindings = String(decoding: try membershipEncoder.encode(memberships), as: UTF8.self)
    let broadPreferences = Set(catalog.filter { preferences.contains($0.id) && !["sport", "team", "ncaa-team", "national-side", "athlete", "driver"].contains($0.kind) }.map(\.id))
    let competitionPreferences = Array(SportsInterestCompetitionScope.competitionIDs(preferredIDs: broadPreferences, catalog: catalog, now: now))
    let sportPreferences = SportsSportHierarchy.descendants(of: Set(catalog.filter { preferences.contains($0.id) && $0.kind == "sport" }.map(\.id)), catalog: catalog)
    let sportCompetitions = Array(catalog.filter { sportPreferences.contains($0.sportID ?? "") && $0.kind == "competition" }.map(\.id))
    let sportEntities = Array(catalog.filter { sportPreferences.contains($0.sportID ?? "") }.map(\.id))
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    let dayStart = calendar.startOfDay(for: now)

    if requestedTeams?.isEmpty == true { return SportsEventsResponse(events: [], updatedAt: nil, degraded: false, preferredIDs: preferences.sorted(), timeZone: timeZoneName ?? timeZone.identifier, schedulesStatus: "empty") }
    let identity = SportsEventTeamIdentity(catalog: catalog, now: now)
    let selectedIDs = SportsSportHierarchy.descendants(of: Set(definition.entityIDs), catalog: catalog)
    let bindings = String(decoding: try JSONEncoder().encode(identity.bindings.filter { selectedIDs.contains($0.entityID) || requestedTeams?.contains($0.entityID) == true || directPreferences.contains($0.entityID) || memberships.map(\.entityID).contains($0.entityID) }), as: UTF8.self)
    let competitionIDs = Set(catalog.filter { selectedIDs.contains($0.sportID ?? "") }.flatMap { $0.competitionIDs + ($0.kind == "competition" ? [$0.id] : []) })
    let eventCompetitionIDs = Array(competitionIDs.union(selectedIDs.filter { id in catalog.contains { $0.id == id && $0.kind == "competition" } }))
    var contextQuery = URLComponents()
    contextQuery.queryItems = [.init(name: "global", value: feed == "sports" ? "true" : "false")]
    if !eventCompetitionIDs.isEmpty { contextQuery.queryItems?.append(.init(name: "competitionIDs", value: eventCompetitionIDs.sorted().joined(separator: ","))) }
    if !selectedIDs.isEmpty { contextQuery.queryItems?.append(.init(name: "entityIDs", value: selectedIDs.sorted().joined(separator: ","))) }
    if let requestedTeams { contextQuery.queryItems?.append(.init(name: "teamIDs", value: requestedTeams.sorted().joined(separator: ","))) }
    if !preferences.isEmpty { contextQuery.queryItems?.append(.init(name: "preferredIDs", value: preferences.sorted().joined(separator: ","))) }
    contextQuery.queryItems?.append(.init(name: "timeZone", value: timeZoneName ?? timeZone.identifier))
    let eventTarget = "/internal/wire/v1/sports/events?" + (contextQuery.percentEncodedQuery ?? "global=true")
    var events: [SportsEvent] = []
    var remoteFailed = false
    if let transport {
      remoteFailed = true
      if let reply = try? await transport.get(target: eventTarget), reply.statusCode == 200,
        reply.contractVersion == 3, let decoded = try? Self.decoder().decode([SportsEvent].self, from: reply.body) {
        remoteFailed = false
        events = Array(decoded.prefix(500))
        let payload = String(decoding: try Self.encoder().encode(events), as: UTF8.self)
        try await pool.query("""
          INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at)
          SELECT event->>'id',event->>'competitionID',event,(event->>'updatedAt')::timestamptz,(event->>'updatedAt')::timestamptz+INTERVAL '72 hours'
          FROM jsonb_array_elements(\(payload)::jsonb) event
          ON CONFLICT(event_id) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at
          """, logger: logger)
      }
    }
    if events.isEmpty {
      let rows = try await pool.query("SELECT payload::text FROM sports_events WHERE expires_at > \(now) AND (\(feed == "sports") OR competition_id=ANY(\(eventCompetitionIDs)::text[]) OR (payload->'entityIDs') ?| \(Array(selectedIDs))::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(bindings)::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY(\(Array(selectedIDs))::text[]) AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))) AND (\(requestedTeams == nil) OR (payload->'entityIDs') ?| \(Array(requestedTeams ?? []))::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(bindings)::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY(\(Array(requestedTeams ?? []))::text[]) AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))) AND (\(preferences.isEmpty) OR ((payload->'entityIDs') ?| \(directPreferences)::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(membershipBindings)::jsonb) membership WHERE (payload->>'startsAt')::timestamptz >= (membership->>'validFrom')::timestamptz AND (membership->>'validUntil' IS NULL OR (payload->>'startsAt')::timestamptz < (membership->>'validUntil')::timestamptz) AND ((payload->'entityIDs') ? (membership->>'entityID') OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(bindings)::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=membership->>'entityID' AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))))) OR competition_id=ANY(\(competitionPreferences + sportCompetitions)::text[]) OR (payload->'entityIDs') ?| \(sportEntities)::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(bindings)::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY(\(directPreferences)::text[]) AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))) AND (payload->>'startsAt')::timestamptz >= \(now.addingTimeInterval(-7*86400)) ORDER BY CASE WHEN payload->>'status'='in-progress' THEN 0 WHEN payload->>'status'='finished' AND (payload->>'startsAt')::timestamptz BETWEEN \(dayStart) AND \(now) THEN 1 WHEN payload->>'status' IN ('scheduled','postponed') AND (payload->>'startsAt')::timestamptz >= \(now) THEN 2 ELSE 3 END, CASE WHEN ((payload->'entityIDs') ?| \(directPreferences)::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(membershipBindings)::jsonb) membership WHERE (payload->>'startsAt')::timestamptz >= (membership->>'validFrom')::timestamptz AND (membership->>'validUntil' IS NULL OR (payload->>'startsAt')::timestamptz < (membership->>'validUntil')::timestamptz) AND ((payload->'entityIDs') ? (membership->>'entityID') OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(bindings)::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=membership->>'entityID' AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))))) OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(bindings)::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY(\(directPreferences)::text[]) AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName')))) THEN 0 WHEN competition_id=ANY(\(competitionPreferences)::text[]) THEN 1 WHEN competition_id=ANY(\(sportCompetitions)::text[]) OR (payload->'entityIDs') ?| \(sportEntities)::text[] THEN 2 ELSE 3 END, abs(extract(epoch FROM ((payload->>'startsAt')::timestamptz - \(now)::timestamptz))), (payload->>'startsAt')::timestamptz, event_id LIMIT 500", logger: logger)
      for try await row in rows { events.append(try Self.decoder().decode(SportsEvent.self, from: Data(try row.decode(String.self).utf8))) }
    }
    var result: [SportsEvent] = []; var updated: Date?
    for cachedEvent in events {
      let event = identity.hydrate(cachedEvent)
      guard preferences.isEmpty || !Set(directPreferences + sportEntities + memberships.filter { $0.includes(event.startsAt) }.map(\.entityID)).isDisjoint(with: event.entityIDs) || Set(competitionPreferences + sportCompetitions).contains(event.competitionID) else { continue }
      guard requestedTeams == nil || !requestedTeams!.isDisjoint(with: event.entityIDs) else { continue }
      if feed == "sports" || selectedIDs.contains(event.competitionID) || competitionIDs.contains(event.competitionID) || !selectedIDs.isDisjoint(with: event.entityIDs) {
        result.append(event); updated = max(updated ?? event.updatedAt, event.updatedAt)
      }
    }
    let standings = try await standings(definition: definition, catalog: catalog, now: now, teamIDs: requestedTeams, preferredIDs: preferences)
    let schedule = try await scheduleStatus(definition: definition, catalog: catalog, now: now, teamIDs: requestedTeams, preferredIDs: preferences)
    return SportsEventsResponse(events: Array(SportsEventOrdering.sorted(result, now: now, preferredIDs: preferences, catalog: catalog, timeZone: timeZone).prefix(500)), updatedAt: updated ?? schedule.updated,
      degraded: remoteFailed || ((updated ?? schedule.updated).map { now.timeIntervalSince($0) > 3600 } ?? true),
      eventsLimited: result.count >= 500, bracketSources: SportsReviewedBracketSources.matching(definition: definition, catalog: catalog, teamIDs: requestedTeams, preferredIDs: preferences, now: now), standings: standings, preferredIDs: preferences.sorted(), timeZone: timeZoneName ?? timeZone.identifier, schedulesStatus: result.isEmpty ? schedule.status : "available")
  }

  private func scheduleStatus(definition: SportsFeedDefinition, catalog: [SportsEntity], now: Date, teamIDs: Set<String>?, preferredIDs: Set<String>) async throws -> (status: String, updated: Date?) {
    if let transport, let reply = try? await transport.get(target: "/internal/wire/v1/sports/schedules"), reply.statusCode == 200,
      reply.contractVersion == 3, let values = try? Self.decoder().decode([SportsScheduleStatus].self, from: reply.body), values.count <= 100 {
      let payload = String(decoding: try Self.encoder().encode(values), as: UTF8.self)
      try await pool.query("""
        INSERT INTO sports_schedule_status(competition_id,payload,updated_at,expires_at)
        SELECT value->>'competitionID',value,(value->>'updatedAt')::timestamptz,(value->>'updatedAt')::timestamptz+INTERVAL '72 hours'
        FROM jsonb_array_elements(\(payload)::jsonb)
        ON CONFLICT(competition_id) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at
        """, logger: logger)
    }
    let selected = SportsSportHierarchy.descendants(of: Set(definition.entityIDs), catalog: catalog)
    let related = Set(catalog.filter { selected.contains($0.id) || selected.contains($0.sportID ?? "") }.flatMap { $0.competitionIDs + ($0.kind == "competition" ? [$0.id] : []) })
    let preferredCompetitions = SportsInterestCompetitionScope.competitionIDs(preferredIDs: preferredIDs, catalog: catalog, now: now)
    let teamCompetitions = Set(catalog.filter { teamIDs?.contains($0.id) == true }.flatMap(\.competitionIDs))
    let rows = try await pool.query("SELECT payload::text FROM sports_schedule_status WHERE expires_at > \(now) AND (\(preferredIDs.isEmpty) OR competition_id=ANY(\(Array(preferredCompetitions))::text[])) AND (\(teamIDs == nil) OR competition_id=ANY(\(Array(teamCompetitions))::text[])) AND (\(definition.id == "sports") OR competition_id=ANY(\(Array(related.union(selected)))::text[])) ORDER BY updated_at DESC LIMIT 100", logger: logger)

    var matching: [SportsScheduleStatus] = []
    for try await row in rows {
      let value = try Self.decoder().decode(SportsScheduleStatus.self, from: Data(try row.decode(String.self).utf8))
      if definition.id == "sports" || selected.contains(value.competitionID) || related.contains(value.competitionID) { matching.append(value) }
    }
    return (matching.isEmpty ? "unavailable" : matching.contains(where: { $0.status == "available" }) ? "available" : "empty", matching.map(\.updatedAt).max())
  }

  private func standings(definition: SportsFeedDefinition, catalog: [SportsEntity], now: Date, teamIDs: Set<String>?, preferredIDs: Set<String>) async throws -> [SportsStandingSnapshot] {
    let preferredCompetitions = SportsInterestCompetitionScope.competitionIDs(preferredIDs: preferredIDs, catalog: catalog, now: now)
    var standingsQuery = URLComponents(); standingsQuery.queryItems = [.init(name: "preferredIDs", value: preferredIDs.sorted().joined(separator: ","))]
    var remoteFailed = false
    if let transport {
      remoteFailed = true
      if let reply = try? await transport.get(target: "/internal/wire/v1/sports/standings?" + (standingsQuery.percentEncodedQuery ?? "")), reply.statusCode == 200,
        reply.contractVersion == 3, let tables = try? Self.decoder().decode([SportsStandingSnapshot].self, from: reply.body), tables.count <= 100 {
        remoteFailed = false
        let payload = String(decoding: try Self.encoder().encode(tables), as: UTF8.self)
        try await pool.query("""
          INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at)
          SELECT value->>'competitionID',value->>'season',value,(value->>'updatedAt')::timestamptz,(value->>'updatedAt')::timestamptz+INTERVAL '72 hours'
          FROM jsonb_array_elements(\(payload)::jsonb) WHERE value->>'updatedAt' IS NOT NULL
          ON CONFLICT(competition_id,season) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at
          """, logger: logger)
      }
    }
    let selected = SportsSportHierarchy.descendants(of: Set(definition.entityIDs), catalog: catalog)
    let related = Set(catalog.filter { selected.contains($0.id) || selected.contains($0.sportID ?? "") }.flatMap { $0.competitionIDs + ($0.kind == "competition" ? [$0.id] : []) })
    let identity = SportsEventTeamIdentity(catalog: catalog, now: now)
    let bindings = String(decoding: try JSONEncoder().encode(identity.bindings.filter { teamIDs?.contains($0.entityID) == true }), as: UTF8.self)
    let rows = try await pool.query("SELECT payload::text FROM sports_standings WHERE expires_at > \(now) AND (\(preferredIDs.isEmpty) OR competition_id=ANY(\(Array(preferredCompetitions))::text[])) AND (\(teamIDs == nil) OR EXISTS (SELECT 1 FROM jsonb_array_elements(payload->'rows') row WHERE row->>'entityID'=ANY(\(Array(teamIDs ?? []))::text[]) OR EXISTS (SELECT 1 FROM jsonb_array_elements(\(bindings)::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY(\(Array(teamIDs ?? []))::text[]) AND binding->>'name'=lower(btrim(row->>'name')) AND row->>'entityID' IS NULL))) AND (\(definition.id == "sports") OR competition_id=ANY(\(Array(related.union(selected)))::text[])) ORDER BY updated_at DESC LIMIT 100", logger: logger)
    var tables: [SportsStandingSnapshot] = []
    for try await row in rows { tables.append(SportsStandingZones.reviewed(identity.hydrate(try Self.decoder().decode(SportsStandingSnapshot.self, from: Data(try row.decode(String.self).utf8))))) }

    var seen = Set<String>()
    let matching = tables.filter { definition.id == "sports" || selected.contains($0.competitionID) || related.contains($0.competitionID) }
      .filter { seen.insert($0.competitionID).inserted }.prefix(20).map { $0.served(at: now, remoteFailed: remoteFailed) }
    if matching.isEmpty, teamIDs == nil, preferredIDs.isEmpty, definition.id != "sports", let competition = related.first ?? selected.first {
      return [.init(competitionID: competition, season: "", status: "unavailable", degraded: remoteFailed)]
    }
    return Array(matching)
  }

  func page(cursor: String?, limit: Int, language: String?, viewerDID: String?, refresh: Bool, now: Date, feed: String = "sports", region: String? = nil) async throws -> SportsPage {
    guard config.mode.canServeAPI else { throw WireServingError.unavailable }
    let lang = Self.language(language)
    guard feed.utf8.count <= 256 else { throw WireServingError.invalidCursor }
    let initialSource = cursor == nil ? try await source(language: lang, now: now) : nil
    let initialCatalog = try await loadCatalog()
    // Named definitions are resolved again after source import, which may hydrate a cold catalog.
    let preference = try await selections.selections(viewerDID: viewerDID, refresh: refresh && cursor == nil, now: now)
    let catalogRevision = Self.catalogRevision(initialCatalog)
    let revision = SportsIdentity.preferenceFingerprint(selections: preference) + ":interests-v2:" + SportsResolver.version + ":" + catalogRevision + ":" + feed + ":" + (region ?? "global")
    let snapshotScope = try hasher.hash(viewerDID ?? "anonymous-sports") + ":" + feed
    let scope = try hasher.hash(viewerDID ?? "anonymous-sports")
    let snapshot: SportsSourceGeneration
    let start: Int
    if let cursor {
      let decoded: SportsCursor
      do { decoded = try codec.decode(cursor, language: lang, preferenceFingerprint: revision, viewerScope: scope, now: now, feed: feed) }
      catch SportsCursorError.expired { throw WireServingError.cursorExpired }
      catch { throw WireServingError.invalidCursor }
      guard let id = UUID(uuidString: decoded.generationID),
        let retained = try await retainedSnapshot(id: id, scope: snapshotScope, language: lang, revision: revision, now: now)
      else { throw WireServingError.cursorExpired }
      snapshot = retained; start = decoded.nextOrdinal
    } else {
      guard let source = initialSource else { throw WireServingError.unavailable }
      guard source.expiresAt > now else { throw WireServingError.unavailable }
      let id = UUID()
      let catalog = try await loadCatalog()
      guard let definition = SportsNamedFeeds.catalog(entities: catalog).first(where: { $0.id == feed }) else { throw WireServingError.invalidCursor }
      let usCompetitionIDs = Set(["nfl", "nba", "wnba", "mlb", "nhl", "mls", "nwsl", "ncaa-football", "ncaa-mens-basketball", "ncaa-womens-basketball", "ncaa-baseball", "ncaa-softball", "ncaa-hockey", "nascar", "indycar"].map { SportsReviewedCatalog.id("competition:" + $0) })
      let byEntityID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let matching = source.candidates.filter { definition.matches($0.analysis) }.map { candidate in
        let competitions = Set(candidate.analysis.competitionIDs + candidate.analysis.associations.flatMap { byEntityID[$0.entityID]?.competitionIDs ?? [] })
        let us = !competitions.isDisjoint(with: usCompetitionIDs)
        let regional = feed == "sports" && !competitions.isEmpty && (region == "outside-us" ? !us : us)
        return SportsRankCandidate(item: candidate.item, analysis: candidate.analysis,
          baseScore: candidate.baseScore * (regional ? 1.05 : 1), majorGlobal: candidate.majorGlobal)
      }
      let ranked = SportsRanker.rank(candidates: matching, selections: preference, catalog: catalog, reserveGlobal: feed == "sports")
      let proposed = SportsSourceGeneration(generationId: id.uuidString.lowercased(), generatedAt: source.generatedAt,
        expiresAt: min(source.expiresAt, now.addingTimeInterval(48 * 60 * 60)), language: lang, candidates: ranked, source: source.source)
      snapshot = try await persistSnapshot(proposed, sourceID: source.generationId, scope: snapshotScope, revision: revision, sourceSnapshot: source)
      start = 0
    }
    guard start <= snapshot.candidates.count else { throw WireServingError.invalidCursor }
    let catalog = try await loadCatalog()
    guard let definition = SportsNamedFeeds.catalog(entities: catalog).first(where: { $0.id == feed }) else { throw WireServingError.invalidCursor }
    let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var accepted: [SportsFeedItem] = []; var ordinal = start
    // getItem rechecks current labels, deletion and viewer state; cached snapshots are never approval.
    while ordinal < snapshot.candidates.count, accepted.count < limit {
      let batchEnd = min(ordinal + 10, snapshot.candidates.count)
      let batch = Array(snapshot.candidates[ordinal..<batchEnd])
      let current = try await withThrowingTaskGroup(of: (String, WireFeedItem?).self) { group in
        for candidate in batch {
          group.addTask { [wire] in
            (candidate.item.itemID, try await wire.getItem(itemId: candidate.item.itemID, viewerDid: viewerDID)?.item)
          }
        }
        var result: [String: WireFeedItem] = [:]
        for try await (id, item) in group { if let item { result[id] = item } }
        return result
      }
      for candidate in batch {
        ordinal += 1
        guard let item = current[candidate.item.itemID] else { continue }
        let unchanged = item.title == candidate.item.title && item.summary == candidate.item.summary
          && item.source.domain == candidate.item.source.domain && SportsCandidateVersionPolicy.isCurrent([candidate])
        let analysis = unchanged ? candidate.analysis : SportsResolver.analyze(title: item.title, summary: item.summary, catalog: catalog)
        guard analysis.eligible, definition.matches(analysis),
          !SportsRanker.rank(candidates: [SportsRankCandidate(item: item, analysis: analysis, baseScore: 1, majorGlobal: candidate.majorGlobal)], selections: preference, catalog: catalog, reserveGlobal: false).isEmpty
        else { continue }
        let associations = analysis.associations.filter { $0.resolverVersion == SportsResolver.version && $0.confidence.isFinite && (0.9...1).contains($0.confidence) && byID[$0.entityID] != nil }
        accepted.append(SportsFeedItem(story: item, entities: associations.compactMap { byID[$0.entityID] },
          associations: associations, materiality: analysis.materiality, majorGlobal: candidate.majorGlobal, sportIDs: analysis.sportIDs, competitionIDs: analysis.competitionIDs))
        if accepted.count == limit { break }
      }
    }
    let next = ordinal < snapshot.candidates.count ? try codec.encode(SportsCursor(feed: feed, generationID: snapshot.generationId,
      language: lang, preferenceFingerprint: revision, viewerScope: scope, nextOrdinal: ordinal, expiresAt: snapshot.expiresAt)) : nil
    let stale = now.timeIntervalSince(snapshot.generatedAt) > 600
    return SportsPage(generationId: snapshot.generationId, generatedAt: snapshot.generatedAt,
      expiresAt: snapshot.expiresAt, language: lang, preferenceRevision: revision, cursor: next,
      source: snapshot.source == .simplifiedFallback ? .simplifiedFallback : stale ? .staleGeneration : .ranked, degraded: stale || snapshot.source == .simplifiedFallback, items: accepted, eventsEnabled: config.eventsEnabled, feedId: feed)
  }

  private func loadCatalog() async throws -> [SportsEntity] {
    let rows = try await pool.query("SELECT payload::text FROM sports_entities ORDER BY entity_id LIMIT 50000", logger: logger)
    var result: [SportsEntity] = []
    for try await row in rows { result.append(try JSONDecoder().decode(SportsEntity.self, from: Data(try row.decode(String.self).utf8))) }
    return result.isEmpty ? SportsReviewedCatalog.entities : result.filter(\.active)
  }

  private func source(language: String, now: Date) async throws -> SportsSourceGeneration {
    if let transport {
      do {
        let reply = try await transport.get(target: "/internal/wire/v1/sports?language=\(language)")
        guard reply.statusCode == 200, reply.contractVersion == 3 else { throw WireServingError.unavailable }
        let source = try Self.decoder().decode(SportsSourceGeneration.self, from: reply.body)
        guard source.language == language, source.expiresAt > now, source.candidates.count <= 5000, SportsCandidateVersionPolicy.isCurrent(source.candidates) else { throw WireServingError.unavailable }
        try await importCatalog(source: source, now: now)
        return source
      } catch {
        if error is CancellationError { throw error }
        logger.warning("Sports corpus unavailable; checking retained generation")
      }
    }
    let rows = try await pool.query("""
      SELECT generation_id, generated_at, expires_at, payload::text, serving_source FROM sports_generations
      WHERE language = \(language) AND expires_at > \(now) ORDER BY is_active DESC, generated_at DESC LIMIT 10
      """, logger: logger)
    for try await row in rows {
      let (id, created, expiry, payload, source) = try row.decode((UUID, Date, Date, String, String).self)
      let candidates = try Self.decoder().decode([SportsRankCandidate].self, from: Data(payload.utf8))
      guard SportsCandidateVersionPolicy.isCurrent(candidates) else { continue }
      return SportsSourceGeneration(generationId: id.uuidString.lowercased(), generatedAt: created,
        expiresAt: expiry, language: language, candidates: candidates, source: WirePageSource(rawValue: source))
    }
    return try await fallback(language: language, now: now)
  }

  private func importCatalog(source: SportsSourceGeneration, now: Date) async throws {
    guard importedCatalogGeneration != source.generationId else { return }
    guard !source.entities.isEmpty, source.entities.count <= 50000 else { throw WireServingError.unavailable }
    let payload = String(decoding: try Self.encoder().encode(source.entities), as: UTF8.self)
    try await pool.query("""
      WITH retired AS (
        UPDATE sports_entities SET payload=jsonb_set(payload, '{active}', 'false'::jsonb), updated_at=\(now)
        WHERE NOT (entity_id = ANY(\(source.entities.map(\.id))::text[]))
      )
      INSERT INTO sports_entities (entity_id, payload, updated_at)
      SELECT entity->>'id', entity, \(now) FROM jsonb_array_elements(\(payload)::jsonb) entity
      ON CONFLICT (entity_id) DO UPDATE SET payload=EXCLUDED.payload, updated_at=EXCLUDED.updated_at
      WHERE sports_entities.payload IS DISTINCT FROM EXCLUDED.payload
      """, logger: logger)
    importedCatalogGeneration = source.generationId
  }

  private func fallback(language: String, now: Date) async throws -> SportsSourceGeneration {
    let catalog = try await loadCatalog()
    let index = SportsEntityIndex(entities: catalog)
    let page = try await wire.getFeed(cursor: nil, limit: 50, language: language, viewerDid: nil, now: now)
    guard page.language == language else { throw WireServingError.unavailable }
    let candidates = page.items.enumerated().compactMap { ordinal, item -> SportsRankCandidate? in
      let analysis = SportsResolver.analyze(title: item.title, summary: item.summary, index: index)
      guard analysis.eligible else { return nil }
      return SportsRankCandidate(item: item, analysis: analysis, baseScore: Double(50 - ordinal),
        majorGlobal: analysis.materiality == "championship" || analysis.materiality == "record")
    }
    guard !candidates.isEmpty else { throw WireServingError.unavailable }
    return SportsSourceGeneration(generationId: UUID().uuidString.lowercased(), generatedAt: now,
      expiresAt: now.addingTimeInterval(48 * 60 * 60), language: language, candidates: candidates, source: .simplifiedFallback)
  }

  private func persistSnapshot(_ snapshot: SportsSourceGeneration, sourceID: String, scope: String, revision: String, sourceSnapshot: SportsSourceGeneration) async throws -> SportsSourceGeneration {
    guard let sourceUUID = UUID(uuidString: sourceID), let id = UUID(uuidString: snapshot.generationId) else { throw WireServingError.unavailable }
    let payload = try Self.encoder().encode(snapshot.candidates)
    // Development imports only the HMAC-authorized public candidate snapshot, never raw network state.
    if transport != nil || snapshot.source == .simplifiedFallback {
      _ = await retention.purgeIfDue(now: Date())
      let sourcePayload = String(decoding: try Self.encoder().encode(sourceSnapshot.candidates), as: UTF8.self)
      try await pool.query("""
        INSERT INTO sports_generations (generation_id, source_generation_id, language, algorithm_version, generated_at, expires_at, payload, serving_source)
        VALUES (\(sourceUUID), \(sourceUUID), \(snapshot.language), 'sports-v1', \(snapshot.generatedAt), \(snapshot.expiresAt), \(sourcePayload)::jsonb, \(snapshot.source?.rawValue ?? "ranked"))
        ON CONFLICT (generation_id) DO NOTHING
        """, logger: logger)
    }
    let rows = try await pool.query("""
      INSERT INTO sports_personalized_snapshots (snapshot_id, source_generation_id, viewer_scope, language, preference_revision, generated_at, expires_at, payload, serving_source)
      VALUES (\(id), \(sourceUUID), \(scope), \(snapshot.language), \(revision), \(snapshot.generatedAt), \(snapshot.expiresAt), \(String(decoding: payload, as: UTF8.self))::jsonb, \(snapshot.source?.rawValue ?? "ranked"))
      ON CONFLICT (source_generation_id, viewer_scope, language, preference_revision) DO UPDATE SET viewer_scope = EXCLUDED.viewer_scope
      RETURNING snapshot_id, generated_at, expires_at, payload::text, serving_source
      """, logger: logger)
    for try await row in rows {
      let (existing, generated, expires, json, source) = try row.decode((UUID, Date, Date, String, String).self)
      let candidates = try Self.decoder().decode([SportsRankCandidate].self, from: Data(json.utf8))
      guard SportsCandidateVersionPolicy.isCurrent(candidates) else { throw WireServingError.cursorExpired }
      return SportsSourceGeneration(generationId: existing.uuidString.lowercased(), generatedAt: generated, expiresAt: expires,
        language: snapshot.language, candidates: candidates, source: WirePageSource(rawValue: source))
    }
    throw WireServingError.unavailable
  }

  private func retainedSnapshot(id: UUID, scope: String, language: String, revision: String, now: Date) async throws -> SportsSourceGeneration? {
    let rows = try await pool.query("""
      SELECT generated_at, expires_at, payload::text, serving_source FROM sports_personalized_snapshots
      WHERE snapshot_id = \(id) AND viewer_scope = \(scope) AND language = \(language)
        AND preference_revision = \(revision) AND expires_at > \(now)
      """, logger: logger)
    for try await row in rows {
      let (generated, expiry, payload, source) = try row.decode((Date, Date, String, String).self)
      let candidates = try Self.decoder().decode([SportsRankCandidate].self, from: Data(payload.utf8))
      guard SportsCandidateVersionPolicy.isCurrent(candidates) else { return nil }
      return SportsSourceGeneration(generationId: id.uuidString.lowercased(), generatedAt: generated, expiresAt: expiry, language: language,
        candidates: candidates, source: WirePageSource(rawValue: source))
    }
    return nil
  }
  private static func catalogRevision(_ entities: [SportsEntity]) -> String {
    let data = (try? encoder().encode(entities.sorted { $0.id < $1.id })) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys; return encoder }
  private static func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
  static func language(_ raw: String?) -> String {
    let primary = (raw ?? "und").lowercased().split(separator: "-").first.map(String.init) ?? "und"
    return primary.count >= 2 && primary.count <= 8 && primary.allSatisfy({ $0.isASCII && $0.isLetter }) ? primary : "und"
  }
}
