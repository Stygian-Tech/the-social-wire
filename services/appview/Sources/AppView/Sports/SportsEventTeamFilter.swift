import Foundation
import SportsCore
import WireCore

/// An explicit empty team selection stays empty instead of broadening to the global schedule.
enum SportsEventTeamFilter {
  static func decode(_ raw: String?) throws -> [String]? {
    guard let raw else { return nil }
    if raw.isEmpty { return [] }
    let ids = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard ids.count <= 100, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.range(of: "^[a-zA-Z0-9:_-]+$", options: .regularExpression) != nil }) else { throw WireServingError.invalidCursor }
    return Array(Set(ids)).sorted()
  }

  static func preferred(_ ids: [String]?, catalog: [SportsEntity]) throws -> Set<String> {
    let active = Set(catalog.filter(\.active).map(\.id))
    guard (ids ?? []).count <= 100, (ids ?? []).allSatisfy({ active.contains($0) }) else { throw WireServingError.invalidCursor }
    return Set(ids ?? [])
  }

  static func timeZone(_ raw: String?) throws -> TimeZone {
    guard let raw else { return TimeZone(secondsFromGMT: 0)! }
    guard raw.utf8.count <= 128, (TimeZone.knownTimeZoneIdentifiers.contains(raw) || ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(raw)), let zone = TimeZone(identifier: raw) else { throw WireServingError.invalidCursor }
    return zone
  }

  static func validate(_ ids: [String]?, catalog: [SportsEntity]) throws -> Set<String>? {
    guard let ids else { return nil }
    guard ids.count <= 100 else { throw WireServingError.invalidCursor }
    let teams = Set(catalog.filter { $0.active && ["team", "ncaa-team", "national-side"].contains($0.kind) }.map(\.id))
    guard ids.allSatisfy({ teams.contains($0) }) else { throw WireServingError.invalidCursor }
    return Set(ids)
  }
}
