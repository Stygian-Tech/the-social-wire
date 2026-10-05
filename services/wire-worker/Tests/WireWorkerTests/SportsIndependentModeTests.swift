import SportsCore
import Testing
import WireCore
@testable import WireWorkerCore

struct SportsIndependentModeTests {
  @Test("Sports source projection stays independent of public Wire visibility", arguments: ["off", "shadow"])
  func independent(wireMode: String) throws {
    let environment = ["DATABASE_URL": "postgres://localhost/wire", "WIRE_FEED_MODE": wireMode,
      "SPORTS_FEED_MODE": "shadow", "WIRE_ACTOR_HMAC_SECRET": String(repeating: "a", count: 32)]
    #expect(try WireWorkerConfig.load(environment).mode == .api)
    let projection = WireWorkerRuntimePlan(mode: .off, role: .drain, cleanupEnabled: false, sportsMode: .shadow)
    #expect(projection.runsSportsProjection)
    #expect(!projection.runsFinanceProjection)
    #expect(SportsFeedMode(environmentValue: nil) == .off)
  }
}
