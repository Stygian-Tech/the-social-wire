import Foundation

public enum SportsEventOrdering {
  /// Resolve interests once per row instead of scanning the catalog per sort comparison.
  public static func sorted(_ events: [SportsEvent], now: Date, preferredIDs: Set<String> = [],
    catalog: [SportsEntity] = [], timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> [SportsEvent] {
    let prepared = events.map { ($0, interestTier($0, preferredIDs: preferredIDs, catalog: catalog)) }
    return prepared.sorted { left, right in
      precedes(left.0, right.0, now: now, timeZone: timeZone, leftInterest: left.1, rightInterest: right.1)
    }.map { $0.0 }
  }
  public static func isInProgress(_ event: SportsEvent) -> Bool {
    event.status == "in-progress"
  }

  /// Refresh timestamps are not finish times. A finished event whose start falls
  /// on the viewer's current game day stays prominent without claiming an end time.
  public static func isRecentResult(_ event: SportsEvent, now: Date,
    timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Bool {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    return event.status == "finished" && event.startsAt <= now
      && calendar.isDate(event.startsAt, inSameDayAs: now)
  }

  public static func interestTier(_ event: SportsEvent, preferredIDs: Set<String>, catalog: [SportsEntity]) -> Int {
    guard !preferredIDs.isEmpty else { return 3 }
    let directKinds: Set<String> = ["team", "national-side", "ncaa-team", "athlete", "driver"]
    let followedDirect = event.entityIDs.contains { id in
      preferredIDs.contains(id) && catalog.contains { $0.id == id && $0.active && directKinds.contains($0.kind) }
    }
    if followedDirect { return 0 }
    if catalog.contains(where: { person in
      person.active && preferredIDs.contains(person.id) && ["athlete", "driver"].contains(person.kind)
        && (person.memberships ?? []).contains { membership in
          membership.includes(event.startsAt) && event.entityIDs.contains(membership.entityID)
            && catalog.contains { $0.id == membership.entityID && $0.active && ["team", "national-side", "ncaa-team"].contains($0.kind) }
        }
    }) { return 0 }
    if preferredIDs.contains(event.competitionID) { return 1 }
    let competition = catalog.first { $0.id == event.competitionID }
    let sportPreferences = SportsSportHierarchy.descendants(of: preferredIDs, catalog: catalog)
    if let sportID = competition?.sportID, sportPreferences.contains(sportID) { return 2 }
    if catalog.contains(where: { event.entityIDs.contains($0.id) && $0.sportID.map(sportPreferences.contains) == true }) { return 2 }
    return 3
  }

  public static func precedes(_ left: SportsEvent, _ right: SportsEvent, now: Date,
    preferredIDs: Set<String> = [], catalog: [SportsEntity] = [],
    timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Bool {
    precedes(left, right, now: now, timeZone: timeZone,
      leftInterest: interestTier(left, preferredIDs: preferredIDs, catalog: catalog),
      rightInterest: interestTier(right, preferredIDs: preferredIDs, catalog: catalog))
  }
  private static func precedes(_ left: SportsEvent, _ right: SportsEvent, now: Date,
    timeZone: TimeZone, leftInterest: Int, rightInterest: Int) -> Bool {
    func priority(_ event: SportsEvent) -> Int {
      if isInProgress(event) { return 0 }
      if isRecentResult(event, now: now, timeZone: timeZone) { return 1 }
      if ["scheduled", "postponed"].contains(event.status), event.startsAt >= now { return 2 }
      return 3
    }
    let leftPriority = priority(left), rightPriority = priority(right)
    if leftPriority != rightPriority { return leftPriority < rightPriority }
    if leftInterest != rightInterest { return leftInterest < rightInterest }
    let leftDistance = abs(left.startsAt.timeIntervalSince(now))
    let rightDistance = abs(right.startsAt.timeIntervalSince(now))
    if leftDistance != rightDistance { return leftDistance < rightDistance }
    if left.startsAt != right.startsAt { return left.startsAt < right.startsAt }
    return left.id < right.id
  }
}
