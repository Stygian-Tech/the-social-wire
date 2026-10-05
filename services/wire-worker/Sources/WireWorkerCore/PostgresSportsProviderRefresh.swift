import Foundation
import Logging
import OperationsCore
import PostgresNIO
import SportsCore

/// One reviewed competition per Coordinator cycle; all readers share this budget and cache.
actor PostgresSportsProviderRefresh {
  private let pool: PostgresClient
  private let logger: Logger
  private let authority: RoleLeaseAuthority?
  private let adapter: TheSportsDBAdapter?
  private let mappings: [String: String]
  private let seasons: [String: String]
  private let tableCompetitions: Set<String>
  private let eventsEnabled: Bool
  init(pool: PostgresClient, logger: Logger, authority: RoleLeaseAuthority?, environment: [String: String], adapter: TheSportsDBAdapter? = nil) {
    self.pool = pool; self.logger = logger; self.authority = authority
    self.eventsEnabled = environment["SPORTS_EVENTS_ENABLED"] == "true"
    // Explicit reviewed opaque-ID -> provider league-ID mappings. Never infer IDs from names.
    self.mappings = (environment["SPORTS_REVIEWED_COMPETITIONS"].flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:])
      .filter { $0.value.range(of: "^[0-9]+$", options: .regularExpression) != nil }
    self.seasons = (environment["SPORTS_REVIEWED_SEASONS"].flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:])
      .filter { TheSportsDBAdapter.validSeason($0.value) }
    self.tableCompetitions = Set(environment["SPORTS_REVIEWED_STANDINGS"].flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
    if environment["SPORTS_PROVIDER_RIGHTS_CONFIRMED"] == "true", let key = environment["THESPORTSDB_API_KEY"], !key.isEmpty {
      self.adapter = adapter ?? .init(apiKey: key)
    } else { self.adapter = nil }
  }
  func run(asOf: Date) async throws {
    guard let adapter, let catalog = try await PostgresSportsCatalogReader.load(pool: pool, logger: logger) else { return }
    var activeCompetitions = Set<String>()
    if eventsEnabled {
      let active = try await pool.query("""
        SELECT DISTINCT competition_id FROM sports_events WHERE expires_at>\(asOf)
          AND (payload->>'status'='in-progress'
            OR (payload->>'startsAt')::timestamptz BETWEEN \(asOf.addingTimeInterval(-6*3600)) AND \(asOf.addingTimeInterval(3600)))
        """, logger: logger)
      for try await row in active { activeCompetitions.insert(try row.decode(String.self)) }
    }
    var resources: [(String, String, String, TimeInterval)] = []
    for entity in catalog.snapshot.entities where entity.kind == "competition" {
      guard let leagueID = mappings[entity.id] else { continue }
      resources.append((SportsProviderRefreshPolicy.key("reference", competitionID: entity.id), entity.id, leagueID, 86400))
      if eventsEnabled {
        resources.append((SportsProviderRefreshPolicy.key("events", competitionID: entity.id), entity.id, leagueID, activeCompetitions.contains(entity.id) ? 300 : 3600))
        if let season = seasons[entity.id] {
          resources.append(("schedule:" + entity.id + ":" + season, entity.id, leagueID, 3600))
          if tableCompetitions.contains(entity.id) {
            resources.append((SportsProviderRefreshPolicy.key("standings", competitionID: entity.id, season: season), entity.id, leagueID, 3600))
          }
        }
      }
    }
    for entity in catalog.snapshot.entities where ["team", "ncaa-team"].contains(entity.kind) {
      if let competition = entity.competitionIDs.first(where: { mappings[$0] != nil }), let nativeID = entity.providerIDs["thesportsdb"] {
        resources.append(("roster:" + entity.id, competition, nativeID, 86400))
      }
    }
    func priority(_ resource: (String, String, String, TimeInterval)) -> Int {
      resource.0.hasPrefix("events:") && resource.3 == 300 ? 0 : (resource.0.hasPrefix("roster:") ? 2 : 1)
    }
    // Select least-recently requested due resource so a large catalog cannot starve later leagues.
    let rows = try await pool.query("SELECT resource_key,requested_at FROM sports_provider_refresh", logger: logger)
    var requested: [String: Date] = [:]
    for try await row in rows { let (key,date) = try row.decode((String,Date).self); requested[key] = date }
    guard let due = resources.filter({ SportsProviderRefreshPolicy.isDue(key: $0.0, interval: $0.3, requested: requested, asOf: asOf) })
      .sorted(by: { priority($0) == priority($1) ? (requested[$0.0] ?? .distantPast) < (requested[$1.0] ?? .distantPast) : priority($0) < priority($1) }).first else { return }
    // Claim before external work under the Coordinator fence. Provider failures leave snapshots unchanged.
    try await pool.withTransaction(logger: logger) { connection in
      if let authority = self.authority { try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: self.logger) }
      try await connection.query("""
        INSERT INTO sports_provider_refresh(resource_key,requested_at) VALUES (\(due.0),\(asOf))
        ON CONFLICT(resource_key) DO UPDATE SET requested_at=EXCLUDED.requested_at
        """, logger: self.logger)
    }
    do {
      if due.0.hasPrefix("standings:"), let season = seasons[due.1] {
        let table = try await adapter.standings(providerLeagueID: due.2, season: season, competitionID: due.1,
          entities: catalog.snapshot.entities, now: asOf)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let payload = String(decoding: try encoder.encode(table), as: UTF8.self)
        try await pool.withTransaction(logger: logger) { connection in
          if let authority = self.authority { try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: self.logger) }
          try await connection.query("""
            INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at)
            VALUES (\(due.1),\(season),\(payload)::jsonb,\(asOf),\(asOf.addingTimeInterval(72*3600)))
            ON CONFLICT(competition_id,season) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at
            """, logger: self.logger)
        }
        return
      }
      if due.0.hasPrefix("events:") || due.0.hasPrefix("schedule:") {
        let upcoming = try await adapter.events(providerLeagueID: due.2, competitionID: due.1, entities: catalog.snapshot.entities, previous: false, now: asOf)
        let recent: [SportsEvent]
        if due.0.hasPrefix("schedule:"), let season = seasons[due.1] {
          recent = try await adapter.seasonEvents(providerLeagueID: due.2, season: season, competitionID: due.1, entities: catalog.snapshot.entities, now: asOf)
        } else {
          recent = try await adapter.events(providerLeagueID: due.2, competitionID: due.1, entities: catalog.snapshot.entities, previous: true, now: asOf)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let fetched = upcoming + recent
        let payload = String(decoding: try encoder.encode(fetched), as: UTF8.self)
        let schedulePayload = String(decoding: try encoder.encode(SportsScheduleStatus(competitionID: due.1,
          status: fetched.isEmpty ? "empty" : "available", updatedAt: asOf)), as: UTF8.self)
        try await pool.withTransaction(logger: logger) { connection in
          if let authority = self.authority { try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: self.logger) }
          try await connection.query("""
            INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at)
            SELECT event->>'id',\(due.1),event,\(asOf),\(asOf.addingTimeInterval(48*3600))
            FROM (SELECT DISTINCT ON (value->>'id') value AS event FROM jsonb_array_elements(\(payload)::jsonb)) unique_events
            ON CONFLICT(event_id) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at
            """, logger: self.logger)
          try await connection.query("""
            INSERT INTO sports_schedule_status(competition_id,payload,updated_at,expires_at)
            VALUES (\(due.1),\(schedulePayload)::jsonb,\(asOf),\(asOf.addingTimeInterval(72*3600)))
            ON CONFLICT(competition_id) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at
            """, logger: self.logger)
        }
        return
      }
      guard let competition = catalog.snapshot.entities.first(where: { $0.id == due.1 }) else { return }
      var entities = catalog.snapshot.entities
      if due.0.hasPrefix("reference:") {
        let mappedCompetition = SportsEntity(id: competition.id, name: competition.name, kind: competition.kind,
          sportID: competition.sportID, competitionIDs: competition.competitionIDs, aliases: competition.aliases,
          providerIDs: competition.providerIDs.merging(["thesportsdb": due.2], uniquingKeysWith: { _, new in new }),
          active: competition.active, memberships: competition.memberships ?? [], schoolID: competition.schoolID,
          gender: competition.gender, division: competition.division, groupPath: competition.groupPath, abbreviation: competition.abbreviation)
        entities.removeAll { $0.id == competition.id }; entities.append(mappedCompetition)
        let records = try await adapter.rows(path: "list/teams/" + due.2)
        for record in records {
          guard let entity = SportsReferenceImport.team(record: record, competition: competition, existing: entities, now: asOf) else { continue }
          entities.removeAll { $0.id == entity.id }; entities.append(entity)
        }
      } else if let team = entities.first(where: { "roster:" + $0.id == due.0 }) {
        let players = try await adapter.rows(path: "list/players/" + due.2)
        let returned = Set(players.compactMap { $0["idPlayer"] })
        // The provider roster is current membership, not a deletion of the person identity.
        entities = entities.map { person in
          guard let nativeID = person.providerIDs["thesportsdb"], ["athlete", "driver"].contains(person.kind),
            players.count < 100, !returned.contains(nativeID), person.memberships?.contains(where: { $0.entityID == team.id && $0.validUntil == nil }) == true else { return person }
          let membership = (person.memberships ?? []).map { relation in
            SportsMembership(entityID: relation.entityID, validFrom: relation.validFrom,
              validUntil: relation.entityID == team.id && relation.validUntil == nil ? asOf : relation.validUntil, season: relation.season)
          }
          return SportsEntity(id: person.id, name: person.name, kind: person.kind, sportID: person.sportID,
            competitionIDs: person.competitionIDs, aliases: person.aliases, providerIDs: person.providerIDs, active: person.active, memberships: membership, schoolID: person.schoolID, gender: person.gender, division: person.division, groupPath: person.groupPath, abbreviation: person.abbreviation)
        }
        for player in players {
          guard let playerID = player["idPlayer"], let name = player["strPlayer"], name.split(separator: " ").count >= 2 else { continue }
          let previous = entities.first { ["athlete", "driver"].contains($0.kind) && $0.providerIDs["thesportsdb"] == playerID }
            ?? entities.first { ["athlete", "driver"].contains($0.kind) && $0.sportID == competition.sportID && $0.name == name }
          var memberships = previous?.memberships ?? []
          if !memberships.contains(where: { $0.entityID == team.id && $0.validUntil == nil }) {
            memberships = memberships.map { .init(entityID: $0.entityID, validFrom: $0.validFrom, validUntil: $0.validUntil ?? asOf, season: $0.season) }
            memberships.append(.init(entityID: team.id, validFrom: asOf))
          }
          let newID = "sp_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
          let identity: String = previous?.id ?? newID
          let kind: String = competition.sportID == SportsReviewedCatalog.id("sport:motorsport") ? "driver" : "athlete"
          let aliases: [String] = previous?.aliases ?? []
          var providers: [String: String] = previous?.providerIDs ?? [:]
          providers["thesportsdb"] = playerID
          let person = SportsEntity(id: identity, name: name, kind: kind, sportID: competition.sportID,
            competitionIDs: [competition.id], aliases: aliases, providerIDs: providers, memberships: memberships, groupPath: previous?.groupPath, abbreviation: previous?.abbreviation)
          entities.removeAll { $0.id == person.id }; entities.append(person)
        }
      }
      guard entities.count <= 50000 else { throw SportsProviderError.invalidResponse }
      let revision = try SportsCatalogSnapshot.revision(entities: entities)
      guard revision != catalog.snapshot.version else { return }
      let snapshot = SportsCatalogSnapshot(version: revision, generatedAt: asOf, entities: entities)
      let payload = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
      try await pool.withTransaction(logger: logger) { connection in
        if let authority = self.authority { try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: self.logger) }
        // Atomic snapshot activation changes the full catalog revision. Projection Pool
        // detects that revision mismatch and reanalyzes bounded article batches; retained
        // analysis remains available for bounded generation revalidation during the sweep.
        try await connection.query("UPDATE sports_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE", logger: self.logger)
        try await connection.query("INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active) VALUES (\(UUID()),\(snapshot.version),\(asOf),\(payload)::jsonb,TRUE)", logger: self.logger)
        try await connection.query("INSERT INTO sports_entities(entity_id,payload,updated_at) SELECT value->>'id',value,\(asOf) FROM jsonb_array_elements(\(payload)::jsonb->'entities') ON CONFLICT(entity_id) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at", logger: self.logger)
      }
    } catch {
      // Defer only our own fenced attempt; preserve the last-successful snapshot.
      let retryClaim = SportsProviderRefreshPolicy.failedClaim(asOf: asOf, interval: due.3)
      try await pool.withTransaction(logger: logger) { connection in
        if let authority = self.authority { try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: self.logger) }
        try await connection.query("UPDATE sports_provider_refresh SET requested_at=\(retryClaim) WHERE resource_key=\(due.0) AND requested_at=\(asOf)", logger: self.logger)
      }
      logger.warning("Sports provider refresh deferred; retaining prior snapshots", metadata: SportsProviderRefreshPolicy.failureMetadata(error))
      throw error
    }
  }
}
