import WireCore

struct WireWorkerRuntimePlan: Equatable, Sendable {
  var runsGeneration: Bool
  var runsDrain: Bool
  var runsCleanup: Bool
  var requiresGenerationReadiness: Bool
  var requiresDrainReadiness: Bool
  var requiresCleanupReadiness: Bool

  init(mode: WireFeedMode, role: WireWorkerRole, cleanupEnabled: Bool) {
    let feedEnabled = mode != .off
    runsGeneration = role.runsGeneration
    runsDrain = feedEnabled && role.runsDrain
    runsCleanup = runsDrain && cleanupEnabled
    requiresGenerationReadiness = feedEnabled && runsGeneration
    requiresDrainReadiness = runsDrain
    requiresCleanupReadiness = runsCleanup
  }
}
