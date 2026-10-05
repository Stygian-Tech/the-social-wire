import Testing
import WireCore
@testable import WireWorkerCore

struct FinanceIndependentModeTests {
  @Test("Finance activates internal source generation and projection independently of public Wire visibility",
    arguments: ["shadow", "api", "visible"], ["off", "shadow"])
  func independentSource(financeMode: String, wireMode: String) throws {
    let environment = ["DATABASE_URL":"postgres://localhost/wire", "WIRE_FEED_MODE":wireMode,
      "FINANCE_FEED_MODE":financeMode, "FINANCE_CATALOG_RIGHTS_CONFIRMED":"true",
      "WIRE_ACTOR_HMAC_SECRET":String(repeating:"s",count:32)]
    let coordinator = try WireWorkerConfig.load(environment, role: .rank)
    #expect(coordinator.mode == .api)
    let coordinatorPlan = WireWorkerRuntimePlan(mode: coordinator.mode, role: .rank, cleanupEnabled: true)
    #expect(coordinatorPlan.runsGeneration && coordinatorPlan.runsMetadataEnrichment)
    let projection = try WireWorkerConfig.load(environment, role: .drain)
    #expect(projection.mode == .api)
    #expect(WireWorkerRuntimePlan(mode: projection.mode, role: .drain, cleanupEnabled: true).runsDrain)
    #expect(environment["WIRE_FEED_MODE"] == wireMode)
  }

  @Test("Finance preserves existing serving Wire modes", arguments: ["api", "visible"])
  func preservesWireServing(wireMode: String) throws {
    let environment = ["DATABASE_URL":"postgres://localhost/wire", "WIRE_FEED_MODE":wireMode,
      "FINANCE_FEED_MODE":"visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED":"true",
      "WIRE_ACTOR_HMAC_SECRET":String(repeating:"s",count:32)]
    #expect(try WireWorkerConfig.load(environment).mode.rawValue == wireMode)
  }

  @Test("unconfirmed or disabled Finance preserves Wire off and enabled source work requires actor secret")
  func sourceGates() throws {
    let base = ["DATABASE_URL":"postgres://localhost/wire", "WIRE_FEED_MODE":"off"]
    #expect(try WireWorkerConfig.load(base.merging(["FINANCE_FEED_MODE":"api"], uniquingKeysWith: { _,new in new })).mode == .off)
    #expect(try WireWorkerConfig.load(base.merging(["FINANCE_FEED_MODE":"off", "FINANCE_CATALOG_RIGHTS_CONFIRMED":"true"], uniquingKeysWith: { _,new in new })).mode == .off)
    #expect(try WireWorkerConfig.load(base.merging(["WIRE_FEED_MODE":"shadow", "FINANCE_FEED_MODE":"api", "WIRE_ACTOR_HMAC_SECRET":String(repeating:"s",count:32)], uniquingKeysWith: { _,new in new })).mode == .shadow)
    let enabled = base.merging(["FINANCE_FEED_MODE":"api", "FINANCE_CATALOG_RIGHTS_CONFIRMED":"true"], uniquingKeysWith: { _,new in new })
    #expect(throws: WireWorkerConfigError.missingActorHMACSecret) { try WireWorkerConfig.load(enabled) }
    #expect(throws: WireWorkerConfigError.invalidActorHMACSecret) {
      try WireWorkerConfig.load(enabled.merging(["WIRE_ACTOR_HMAC_SECRET":"short"], uniquingKeysWith: { _,new in new }))
    }
  }
}
