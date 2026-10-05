import FinanceCore
import SportsCore
import WireCore

struct WireWorkerRuntimePlan: Equatable, Sendable {
  var runsGeneration: Bool
  var runsFinanceProjection: Bool
  var runsSportsProjection: Bool
  var runsDrain: Bool
  var runsCleanup: Bool
  var runsGraphMaintenance: Bool
  var runsMetadataEnrichment: Bool
  var requiresGenerationReadiness: Bool
  var requiresDrainReadiness: Bool
  var requiresCleanupReadiness: Bool

  init(mode: WireFeedMode, role: WireWorkerRole, cleanupEnabled: Bool, financeMode: FinanceFeedMode = .off, financeRightsConfirmed: Bool = false, sportsMode: SportsFeedMode = .off) {
    let feedEnabled = mode != .off
    runsGeneration = role.runsGeneration
    runsDrain = feedEnabled && role.runsDrain
    runsSportsProjection = role.runsDrain && sportsMode != .off
    runsFinanceProjection = role.runsDrain && financeMode != .off && financeRightsConfirmed
    runsCleanup = feedEnabled && cleanupEnabled && role.runsGeneration
    // Enrichment is generation input, not inbox acknowledgement. Keep it on the
    // singleton rank lane so horizontally scaled drain replicas devote their
    // database pool and HTTP capacity to reducing inbox lag. Terminal cleanup
    // follows the same ownership boundary.
    runsGraphMaintenance = feedEnabled && runsGeneration
    runsMetadataEnrichment = feedEnabled && runsGeneration
    requiresGenerationReadiness = feedEnabled && runsGeneration
    requiresDrainReadiness = runsDrain
    requiresCleanupReadiness = runsCleanup
  }
}
