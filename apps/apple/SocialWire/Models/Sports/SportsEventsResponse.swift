import Foundation

struct SportsEventsResponse: Codable, Equatable, Sendable {
    let events: [SportsEvent]
    let updatedAt: String?
    let degraded: Bool
    var schedulesStatus: String? = nil
    var standings: [SportsStandingSnapshot]? = nil
    var bracketSources: [SportsBracketSource]? = nil
    var eventsLimited: Bool? = nil
    var preferredIDs: [String]? = nil
    var timeZone: String? = nil

    func featuredEvent(now: Date) -> SportsEvent? {
        if let active = events.filter({ $0.status == "in-progress" }).min(by: { $0.startsAt < $1.startsAt }) { return active }
        return events.filter { $0.status == "finished" && (ISO8601DateFormatter().date(from: $0.startsAt).map { $0 <= now } ?? false) }
            .max { $0.startsAt < $1.startsAt }
    }

    func upcomingEvents(now: Date, limit: Int = 3) -> [SportsEvent] {
        Array(events.filter { ["scheduled", "postponed"].contains($0.status)
            && (ISO8601DateFormatter().date(from: $0.startsAt).map { $0 >= now } ?? false) }
            .sorted { $0.startsAt == $1.startsAt ? $0.id < $1.id : $0.startsAt < $1.startsAt }.prefix(max(0, limit)))
    }

    func matchesOrderingContext(preferredIDs requestedIDs: [String], timeZone requestedZone: String) -> Bool {
        guard !requestedIDs.isEmpty else { return true }
        return preferredIDs.map(Set.init) == Set(requestedIDs) && timeZone == requestedZone
    }

    func matchesTeamScope(_ teamIDs: [String]) -> Bool {
        let scope = Set(teamIDs)
        return events.allSatisfy { !scope.isDisjoint(with: $0.entityIDs) }
            && (standings ?? []).allSatisfy { table in
                table.rows.isEmpty || table.rows.contains { row in row.entityID.map(scope.contains) ?? false }
            }
    }
}
