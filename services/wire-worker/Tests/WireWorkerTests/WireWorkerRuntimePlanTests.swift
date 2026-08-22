import Testing
import WireCore
@testable import WireWorker

struct WireWorkerRuntimePlanTests {
  @Test("combined worker owns every enabled runtime")
  func combinedEnabled() {
    let plan = WireWorkerRuntimePlan(mode: .api, role: .combined, cleanupEnabled: true)
    #expect(plan.runsGeneration)
    #expect(plan.runsDrain)
    #expect(plan.runsCleanup)
    #expect(plan.runsMetadataEnrichment)
    #expect(plan.requiresGenerationReadiness)
    #expect(plan.requiresDrainReadiness)
    #expect(plan.requiresCleanupReadiness)
  }

  @Test("rank worker never drains or cleans")
  func rankEnabled() {
    let plan = WireWorkerRuntimePlan(mode: .api, role: .rank, cleanupEnabled: true)
    #expect(plan.runsGeneration)
    #expect(!plan.runsDrain)
    #expect(!plan.runsCleanup)
    #expect(!plan.runsMetadataEnrichment)
    #expect(plan.requiresGenerationReadiness)
    #expect(!plan.requiresDrainReadiness)
    #expect(!plan.requiresCleanupReadiness)
  }

  @Test("drain worker never enters generation")
  func drainEnabled() {
    let plan = WireWorkerRuntimePlan(mode: .api, role: .drain, cleanupEnabled: true)
    #expect(!plan.runsGeneration)
    #expect(plan.runsDrain)
    #expect(plan.runsCleanup)
    #expect(plan.runsMetadataEnrichment)
    #expect(!plan.requiresGenerationReadiness)
    #expect(plan.requiresDrainReadiness)
    #expect(plan.requiresCleanupReadiness)
  }

  @Test("cleanup ownership can be disabled independently")
  func cleanupDisabled() {
    let plan = WireWorkerRuntimePlan(mode: .api, role: .drain, cleanupEnabled: false)
    #expect(plan.runsDrain)
    #expect(!plan.runsCleanup)
    #expect(plan.runsMetadataEnrichment)
    #expect(plan.requiresDrainReadiness)
    #expect(!plan.requiresCleanupReadiness)
  }

  @Test("off remains a universal work and readiness kill switch for drain")
  func drainOff() {
    let plan = WireWorkerRuntimePlan(mode: .off, role: .drain, cleanupEnabled: true)
    #expect(!plan.runsGeneration)
    #expect(!plan.runsDrain)
    #expect(!plan.runsCleanup)
    #expect(!plan.runsMetadataEnrichment)
    #expect(!plan.requiresGenerationReadiness)
    #expect(!plan.requiresDrainReadiness)
    #expect(!plan.requiresCleanupReadiness)
  }

  @Test("combined off preserves the existing no-op generation runtime")
  func combinedOff() {
    let plan = WireWorkerRuntimePlan(mode: .off, role: .combined, cleanupEnabled: true)
    #expect(plan.runsGeneration)
    #expect(!plan.runsDrain)
    #expect(!plan.runsCleanup)
    #expect(!plan.runsMetadataEnrichment)
    #expect(!plan.requiresGenerationReadiness)
    #expect(!plan.requiresDrainReadiness)
    #expect(!plan.requiresCleanupReadiness)
  }
}
