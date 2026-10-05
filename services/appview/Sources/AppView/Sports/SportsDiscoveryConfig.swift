import Foundation
import SportsCore

struct SportsDiscoveryConfig: Sendable {
  let mode: SportsFeedMode
  let cursorSecret: String?
  let eventsEnabled: Bool
  var corpusEdge: WireCorpusRemoteConfig? = nil
  static let disabled = Self(mode: .off, cursorSecret: nil, eventsEnabled: false)
  static func fromEnvironment(_ env: [String: String]) throws -> Self {
    let raw = env["SPORTS_FEED_MODE"]?.lowercased() ?? "off"
    guard let mode = SportsFeedMode(rawValue: raw) else { throw WireDiscoveryConfigError.invalidMode(raw) }
    let remote = try WireCorpusRemoteConfig.fromEnvironment([
      "APP_ENV": env["APP_ENV"] ?? "",
      "WIRE_CORPUS_EDGE_BASE_URL": env["SPORTS_CORPUS_EDGE_BASE_URL"] ?? "",
      "WIRE_CORPUS_EDGE_SERVICE_ID": env["SPORTS_CORPUS_EDGE_SERVICE_ID"] ?? "",
      "WIRE_CORPUS_EDGE_HMAC_SECRET": env["SPORTS_CORPUS_EDGE_HMAC_SECRET"] ?? ""])
    return Self(mode: mode, cursorSecret: env["SPORTS_CURSOR_HMAC_SECRET"] ?? env["WIRE_CURSOR_HMAC_SECRET"],
      eventsEnabled: env["SPORTS_EVENTS_ENABLED"]?.lowercased() == "true", corpusEdge: remote)
  }
}
