import Foundation

enum CircleDiscoveryConfigError: Error, Equatable {
  case invalidMode(String)
  case missingActorSecret
  case invalidActorSecret
  case missingCursorSecret
  case invalidCursorSecret
}

enum CircleDiscoveryMode: String, Sendable {
  case off
  case api
  case visible

  var servesAPI: Bool { self == .api || self == .visible }
  var isVisible: Bool { self == .visible }
}

struct CircleDiscoveryConfig: Sendable {
  let mode: CircleDiscoveryMode
  let actorSecret: String?
  let cursorSecret: String?

  static func fromEnvironment(_ environment: [String: String]) throws -> CircleDiscoveryConfig {
    let rawMode = environment["CIRCLE_FEED_MODE"]?.lowercased() ?? CircleDiscoveryMode.off.rawValue
    guard let mode = CircleDiscoveryMode(rawValue: rawMode) else {
      throw CircleDiscoveryConfigError.invalidMode(rawMode)
    }
    let actorSecret = nonempty(environment["WIRE_ACTOR_HMAC_SECRET"])
    let cursorSecret = nonempty(environment["CIRCLE_CURSOR_HMAC_SECRET"])
    if mode.servesAPI {
      guard let actorSecret else { throw CircleDiscoveryConfigError.missingActorSecret }
      guard actorSecret.utf8.count >= 32 else {
        throw CircleDiscoveryConfigError.invalidActorSecret
      }
      guard let cursorSecret else { throw CircleDiscoveryConfigError.missingCursorSecret }
      guard cursorSecret.utf8.count >= 32 else {
        throw CircleDiscoveryConfigError.invalidCursorSecret
      }
    }
    return CircleDiscoveryConfig(
      mode: mode,
      actorSecret: actorSecret,
      cursorSecret: cursorSecret
    )
  }

  private static func nonempty(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}
