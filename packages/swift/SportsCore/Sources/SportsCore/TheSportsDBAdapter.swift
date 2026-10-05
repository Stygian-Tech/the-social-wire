import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// V2 uses header authentication. No artwork, viewer identity or OAuth credentials leave this adapter.
public struct TheSportsDBAdapter: Sendable {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
  private let apiKey: String
  private let transport: Transport
  public init(apiKey: String, transport: @escaping Transport = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }) { self.apiKey = apiKey; self.transport = transport }
  public func rows(path: String) async throws -> [[String: String]] {
    guard !apiKey.isEmpty, path.range(of: "^[a-z0-9/-]+$", options: .regularExpression) != nil,
      let url = URL(string: "https://www.thesportsdb.com/api/v2/json/" + path) else { throw SportsProviderError.invalidResponse }
    return try await rows(url: url, headerAuthentication: true)
  }
  private func rows(url: URL, headerAuthentication: Bool) async throws -> [[String: String]] {
    var request = URLRequest(url: url); request.timeoutInterval = 12
    if headerAuthentication { request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY") }
    var attempt = 0
    while true {
      let (data, status) = try await transport(request)
      if status >= 500, attempt < 2 {
        attempt += 1; try await Task.sleep(for: .seconds(attempt * 2)); continue
      }
      guard status == 200, data.count <= 4_000_000,
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let array = root.values.compactMap({ $0 as? [[String: Any]] }).first ?? (["table", "schedule", "events", "list", "lookup"].contains(where: { root[$0] is NSNull }) ? [] : nil) else { throw SportsProviderError.invalidResponse }
      guard array.count <= 3000 else { throw SportsProviderError.invalidResponse }
      return array.map { $0.reduce(into: [String: String]()) { result, pair in
        if let value = pair.value as? String { result[pair.key] = value }
        else if let number = pair.value as? NSNumber { result[pair.key] = number.stringValue }
      } }
    }
  }
  public func events(providerLeagueID: String, competitionID: String, entities: [SportsEntity], previous: Bool, now: Date) async throws -> [SportsEvent] {
    let records = try await rows(path: "schedule/" + (previous ? "previous" : "next") + "/league/" + providerLeagueID)
    return records.compactMap { Self.event($0, competitionID: competitionID, entities: entities, now: now) }
  }
  public func seasonEvents(providerLeagueID: String, season: String, competitionID: String,
    entities: [SportsEntity], now: Date) async throws -> [SportsEvent] {
    guard Self.validID(providerLeagueID), Self.validSeason(season) else { throw SportsProviderError.invalidResponse }
    let records = try await rows(path: "schedule/league/" + providerLeagueID + "/" + season)
    let parsed = records.compactMap { Self.event($0, competitionID: competitionID, entities: entities, now: now) }
    guard parsed.count == records.count else { throw SportsProviderError.invalidResponse }
    return parsed
  }

  /// The documented table endpoint is V1 and limited to featured football leagues.
  /// Call only for competitions whose table coverage has separately been reviewed.
  public func standings(providerLeagueID: String, season: String, competitionID: String,
    entities: [SportsEntity], now: Date) async throws -> SportsStandingSnapshot {
    guard Self.validID(providerLeagueID), Self.validSeason(season),
      apiKey.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil,
      let url = URL(string: "https://www.thesportsdb.com/api/v1/json/" + apiKey + "/lookuptable.php?l=" + providerLeagueID + "&s=" + season)
    else { throw SportsProviderError.invalidResponse }
    let records = try await rows(url: url, headerAuthentication: false)
    let tableSource = "https://www.thesportsdb.com/table.php?l=" + providerLeagueID + "&s=" + season
    let parsed = records.compactMap { Self.standing($0, competitionID: competitionID, entities: entities, sourceURL: tableSource) }
    // A partially malformed response must not replace a last-successful table.
    guard parsed.count == records.count else { throw SportsProviderError.invalidResponse }
    return SportsStandingZones.reviewed(.init(competitionID: competitionID, season: season,
      sourceURL: "https://www.thesportsdb.com/league/" + providerLeagueID,
      status: parsed.isEmpty ? "empty" : "available", updatedAt: now, rows: parsed))
  }

  public static func standing(_ row: [String: String], competitionID: String, entities: [SportsEntity], sourceURL: String = "https://www.thesportsdb.com/") -> SportsStandingRow? {
    guard let nativeID = row["idTeam"], validID(nativeID),
      let name = row["strTeam"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let matches = entities.filter { ["team", "ncaa-team"].contains($0.kind)
      && $0.competitionIDs.contains(competitionID) && $0.providerIDs["thesportsdb"] == nativeID }
    func statistic(_ key: String) -> Int? { row[key].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } }
    return .init(id: "tsdb:" + nativeID, entityID: matches.count == 1 ? matches[0].id : nil,
      name: name, rank: statistic("intRank"), played: statistic("intPlayed"), won: statistic("intWin"),
      drawn: statistic("intDraw"), lost: statistic("intLoss"), points: row["intPoints"], group: row["strGroup"],
      zone: SportsStandingZones.provider(description: row["strDescription"], sourceURL: sourceURL))
  }

  public static func validSeason(_ value: String) -> Bool {
    value.range(of: "^[0-9]{4}(-[0-9]{4})?$", options: .regularExpression) != nil
  }
  private static func validID(_ value: String) -> Bool {
    value.range(of: "^[0-9]+$", options: .regularExpression) != nil
  }
  public static func event(_ row: [String: String], competitionID: String, entities: [SportsEntity], now: Date) -> SportsEvent? {
    guard let nativeID = row["idEvent"], !nativeID.isEmpty, let title = row["strEvent"], !title.isEmpty else { return nil }
    let explicitDate = row["strTimestamp"].flatMap(SportsProviderTimestamp.parse)
    let eventDay = row["dateEvent"] ?? ""
    let clockTime = row["strTime"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let validClock = clockTime.flatMap { time in
      guard time.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$", options: .regularExpression) != nil else { return nil as Date? }
      return SportsProviderTimestamp.parse(eventDay + "T" + (time.count == 5 ? time + ":00" : time) + "Z")
    }
    guard let date = explicitDate ?? validClock ?? SportsProviderTimestamp.parse(eventDay + "T00:00:00Z") else { return nil }
    let startTimeKnown = explicitDate != nil || validClock != nil
    let status = TheSportsDBEventStatus.normalize(row["strStatus"])
    let providerTeamIDs = Set([row["idHomeTeam"], row["idAwayTeam"]].compactMap { $0 })
    let ids = entities.filter { ["team", "ncaa-team"].contains($0.kind) && $0.competitionIDs.contains(competitionID) && ($0.providerIDs["thesportsdb"].map(providerTeamIDs.contains) ?? false) }.map(\.id)
    return .init(id: "tsdb:" + nativeID, competitionID: competitionID, entityIDs: ids, title: title, startsAt: date,
      status: status, homeName: row["strHomeTeam"], awayName: row["strAwayTeam"],
      homeScore: ["finished", "in-progress"].contains(status) ? row["intHomeScore"] : nil,
      awayScore: ["finished", "in-progress"].contains(status) ? row["intAwayScore"] : nil, startTimeKnown: startTimeKnown, updatedAt: now)
  }
}
