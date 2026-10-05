import SportsCore
import Testing
@testable import AppView

@Suite("Sports discovery configuration")
struct SportsDiscoveryConfigTests {
  @Test func defaultsOff() throws {
    let config = try SportsDiscoveryConfig.fromEnvironment([:])
    #expect(config.mode == .off)
    #expect(!config.eventsEnabled)
  }
  @Test func independentEventGate() throws {
    let config = try SportsDiscoveryConfig.fromEnvironment(["SPORTS_FEED_MODE": "api", "SPORTS_EVENTS_ENABLED": "true", "WIRE_CURSOR_HMAC_SECRET": "secret"])
    #expect(config.mode.canServeAPI)
    #expect(config.eventsEnabled)
    #expect(config.cursorSecret == "secret")
    #expect(try SportsDiscoveryConfig.fromEnvironment(["SPORTS_FEED_MODE": "shadow"]).mode.canServeAPI == false)
  }
  @Test func invalidModeFailsClosed() {
    #expect(throws: (any Error).self) { try SportsDiscoveryConfig.fromEnvironment(["SPORTS_FEED_MODE": "enabled"]) }
  }
}
