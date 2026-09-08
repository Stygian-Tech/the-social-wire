import Testing

@testable import WireWorkerCore

extension WireWorkerConfigTests {
  @Test("automatic hydration defaults off and its Coordinator requires an explicit source scope")
  func dependencyHydrationRequiresScopedRollout() throws {
    #expect(try !WireWorkerConfig.load(["DATABASE_URL": "postgres://localhost/wire"]).dependencyVerificationEnabled)
    #expect(throws: WireWorkerConfigError.missingInboxEnvironment) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://localhost/wire", "WIRE_DEPENDENCY_HYDRATION_ENABLED": "true",
        "WIRE_WORKER_ROLE": "rank",
      ])
    }
    let config = try WireWorkerConfig.load([
      "DATABASE_URL": "postgres://localhost/wire", "WIRE_DEPENDENCY_HYDRATION_ENABLED": "TRUE",
      "APP_ENV": "dev", "WIRE_INBOX_SOURCE_GENERATIONS": "live",
      "WIRE_WORKER_ROLE": "rank",
    ])
    #expect(config.dependencyVerificationEnabled)
    #expect(config.inboxSourceScope?.environment == "dev")
    for role in ["drain", "combined"] {
      let guardOnly = try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://localhost/wire", "WIRE_DEPENDENCY_HYDRATION_ENABLED": "true",
        "WIRE_WORKER_ROLE": role,
      ])
      #expect(guardOnly.dependencyVerificationEnabled)
      #expect(guardOnly.inboxSourceScope == nil)
    }
  }

  @Test("the automatic hydration rollout rejects an invalid switch value")
  func dependencyHydrationRejectsInvalidSwitch() {
    #expect(throws: WireWorkerConfigError.invalidBoolean("WIRE_DEPENDENCY_HYDRATION_ENABLED")) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://localhost/wire", "WIRE_DEPENDENCY_HYDRATION_ENABLED": "sometimes",
        "APP_ENV": "dev", "WIRE_INBOX_SOURCE_GENERATIONS": "live",
      ])
    }
  }
}
