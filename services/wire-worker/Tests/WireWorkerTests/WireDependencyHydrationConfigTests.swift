import Testing

@testable import WireWorkerCore

extension WireWorkerConfigTests {
  @Test("automatic hydration defaults off and its Coordinator requires an explicit environment")
  func dependencyHydrationRequiresEnvironment() throws {
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
    #expect(config.dependencyRecoveryEnvironment == "dev")
    for role in ["drain", "combined"] {
      let guardOnly = try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://localhost/wire", "WIRE_DEPENDENCY_HYDRATION_ENABLED": "true",
        "WIRE_WORKER_ROLE": role,
      ])
      #expect(guardOnly.dependencyVerificationEnabled)
      #expect(guardOnly.inboxSourceScope == nil)
      #expect(guardOnly.dependencyRecoveryEnvironment == nil)
    }
  }

  @Test("Coordinator hydration uses its environment without narrowing the existing intake",
    arguments: ["dev", "prod"])
  func dependencyHydrationAllowsUnscopedCoordinator(environment: String) throws {
    let config = try WireWorkerConfig.load([
      "DATABASE_URL": "postgres://localhost/wire", "WIRE_DEPENDENCY_HYDRATION_ENABLED": "true",
      "WIRE_WORKER_ROLE": "rank", "APP_ENV": environment,
    ])
    #expect(config.dependencyVerificationEnabled)
    #expect(config.dependencyRecoveryEnvironment == environment)
    #expect(config.inboxSourceScope == nil)
  }

  @Test("Coordinator hydration rejects an invalid recovery environment even when intake is unscoped")
  func dependencyHydrationRejectsInvalidEnvironment() {
    #expect(throws: WireWorkerConfigError.invalidInboxEnvironment("staging")) {
      try WireWorkerConfig.load([
        "DATABASE_URL": "postgres://localhost/wire", "WIRE_DEPENDENCY_HYDRATION_ENABLED": "true",
        "WIRE_WORKER_ROLE": "rank", "APP_ENV": "staging",
      ])
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
