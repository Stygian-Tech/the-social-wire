import Foundation
import SportsCore

struct SportsEventsResponse: Codable, Sendable {
  let events: [SportsEvent]
  let updatedAt: Date?
  let degraded: Bool
  var eventsLimited: Bool = false
  var bracketSources: [SportsBracketSource] = []
  var standings: [SportsStandingSnapshot] = []
  var preferredIDs: [String]? = nil
  var timeZone: String? = nil
  var schedulesStatus: String = "unavailable"
}
