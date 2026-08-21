import Foundation

enum WireDiscoveryConfigError: Error, Equatable {
  case invalidMode(String)
}

enum WireDiscoveryMode: String, Sendable {
  case off
  case shadow
  case api
  case visible

  var servesAPI: Bool { self == .api || self == .visible }
  var isVisible: Bool { self == .visible }
}

struct WireDiscoveryConfig: Sendable {
  let mode: WireDiscoveryMode
  let cursorSecret: String?

  static func fromEnvironment(_ environment: [String: String]) throws -> WireDiscoveryConfig {
    let rawMode = environment["WIRE_FEED_MODE"]?.lowercased() ?? WireDiscoveryMode.off.rawValue
    guard let mode = WireDiscoveryMode(rawValue: rawMode) else {
      throw WireDiscoveryConfigError.invalidMode(rawMode)
    }
    let rawSecret = environment["WIRE_CURSOR_HMAC_SECRET"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return WireDiscoveryConfig(
      mode: mode,
      cursorSecret: rawSecret?.isEmpty == false ? rawSecret : nil
    )
  }
}
