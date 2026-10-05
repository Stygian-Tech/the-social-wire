import Foundation
import SportsCore

struct SportsFeedAvailability: Codable, Sendable {
  let enabled: Bool
  let available: Bool
  let eventsEnabled: Bool
  var feeds: [SportsFeedDefinition] = []
  var entities: [SportsEntity] = []
  var version: String = SportsNamedFeeds.version
}
