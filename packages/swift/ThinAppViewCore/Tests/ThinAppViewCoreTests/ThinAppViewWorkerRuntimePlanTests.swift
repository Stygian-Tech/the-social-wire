import Testing

@testable import ThinAppViewCore

@Suite("Thin AppView worker runtime plan")
struct ThinAppViewWorkerRuntimePlanTests {
  @Test("combined preserves the legacy all-in-one runtime")
  func combinedPlan() {
    let plan = ThinAppViewWorkerRuntimePlan(role: .combined)

    #expect(plan.runsLegacySubscriber)
    #expect(plan.runsInboxProjection)
    #expect(plan.runsProjectionRepair)
    #expect(plan.runsTapConsumer)
    #expect(plan.runsTtlCleanup)
    #expect(plan.runsProactiveBackfill)
    #expect(plan.runsRecovery)
    #expect(plan.runsRssPolling)
    #expect(plan.runsTelemetry)
    #expect(plan.runsHeartbeat)
  }

  @Test("projection contains only horizontally safe queue work")
  func projectionPlan() {
    let plan = ThinAppViewWorkerRuntimePlan(role: .projection)

    #expect(!plan.runsLegacySubscriber)
    #expect(plan.runsInboxProjection)
    #expect(plan.runsProjectionRepair)
    #expect(!plan.runsTapConsumer)
    #expect(!plan.runsTtlCleanup)
    #expect(!plan.runsProactiveBackfill)
    #expect(!plan.runsRecovery)
    #expect(!plan.runsRssPolling)
    #expect(plan.runsTelemetry)
    #expect(plan.runsHeartbeat)
  }

  @Test("coordinator excludes scalable inbox claims")
  func coordinatorPlan() {
    let plan = ThinAppViewWorkerRuntimePlan(role: .coordinator)

    #expect(!plan.runsLegacySubscriber)
    #expect(!plan.runsInboxProjection)
    #expect(!plan.runsProjectionRepair)
    #expect(plan.runsTapConsumer)
    #expect(plan.runsTtlCleanup)
    #expect(plan.runsProactiveBackfill)
    #expect(plan.runsRecovery)
    #expect(plan.runsRssPolling)
    #expect(plan.runsTelemetry)
    #expect(plan.runsHeartbeat)
  }
}
