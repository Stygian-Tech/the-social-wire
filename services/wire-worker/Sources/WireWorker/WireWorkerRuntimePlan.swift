import WireCore

struct WireWorkerRuntimePlan: Equatable, Sendable {
  var runsGeneration: Bool
  var runsDrain: Bool
  var runsCleanup: Bool
  var runsMetadataEnrichment: Bool
  var requiresGenerationReadiness: Bool
  var requiresDrainReadiness: Bool
  var requiresCleanupReadiness: Bool

  init(mode: WireFeedMode, role: WireWorkerRole, cleanupEnabled: Bool) {
    let feedEnabled = mode != .off
    runsGeneration = role.runsGeneration
    runsDrain = feedEnabled && role.runsDrain
    runsCleanup = feedEnabled && cleanupEnabled
    // Enrichment is generation input, not inbox acknowledgement. Keep it on the
    // singleton rank lane so horizontally scaled drain replicas devote their
    // database pool and HTTP capacity to reducing inbox lag.
    runsMetadataEnrichment = feedEnabled && runsGeneration
    requiresGenerationReadiness = feedEnabled && runsGeneration
    requiresDrainReadiness = runsDrain
    requiresCleanupReadiness = runsCleanup
  }
}
