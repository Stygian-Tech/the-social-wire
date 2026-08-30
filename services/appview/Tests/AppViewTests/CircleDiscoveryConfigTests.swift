import Testing

@testable import AppView

@Suite("Your Circle discovery configuration")
struct CircleDiscoveryConfigTests {
  @Test("defaults off without requiring secrets")
  func defaultsOff() throws {
    let config = try CircleDiscoveryConfig.fromEnvironment([:])
    #expect(config.mode == .off)
    #expect(config.actorSecret == nil)
    #expect(config.cursorSecret == nil)
  }

  @Test("API modes require independent strong actor and cursor secrets")
  func requiresStrongSecrets() throws {
    #expect(throws: CircleDiscoveryConfigError.missingActorSecret) {
      try CircleDiscoveryConfig.fromEnvironment(["CIRCLE_FEED_MODE": "api"])
    }
    #expect(throws: CircleDiscoveryConfigError.invalidActorSecret) {
      try CircleDiscoveryConfig.fromEnvironment([
        "CIRCLE_FEED_MODE": "visible",
        "WIRE_ACTOR_HMAC_SECRET": "short",
        "CIRCLE_CURSOR_HMAC_SECRET": String(repeating: "c", count: 32),
      ])
    }
    #expect(throws: CircleDiscoveryConfigError.invalidCursorSecret) {
      try CircleDiscoveryConfig.fromEnvironment([
        "CIRCLE_FEED_MODE": "api",
        "WIRE_ACTOR_HMAC_SECRET": String(repeating: "a", count: 32),
        "CIRCLE_CURSOR_HMAC_SECRET": "short",
      ])
    }
    let config = try CircleDiscoveryConfig.fromEnvironment([
      "CIRCLE_FEED_MODE": "visible",
      "WIRE_ACTOR_HMAC_SECRET": String(repeating: "a", count: 32),
      "CIRCLE_CURSOR_HMAC_SECRET": String(repeating: "c", count: 32),
    ])
    #expect(config.mode == .visible)
    #expect(config.mode.servesAPI)
    #expect(config.mode.isVisible)
  }

  @Test("unknown modes fail closed")
  func invalidMode() {
    #expect(throws: CircleDiscoveryConfigError.invalidMode("rank")) {
      try CircleDiscoveryConfig.fromEnvironment(["CIRCLE_FEED_MODE": "rank"])
    }
  }
}
