import Foundation
import WireCore

struct WireWorkerCycle: Sendable {
  let store: any WireGenerationStore
  let config: WireWorkerConfig
  let inboxMaintainer: (any WireInboxMaintaining)?
  let labelRefresher: (any WireBaselineLabelRefreshing)?

  init(
    store: any WireGenerationStore,
    config: WireWorkerConfig,
    inboxMaintainer: (any WireInboxMaintaining)? = nil,
    labelRefresher: (any WireBaselineLabelRefreshing)? = nil
  ) {
    self.store = store
    self.config = config
    self.inboxMaintainer = inboxMaintainer
    self.labelRefresher = labelRefresher
  }

  func run(asOf: Date) async throws -> WireWorkerCycleOutcome {
    try await store.ping()
    guard config.mode != .off else { return .off }
    try await inboxMaintainer?.maintain(asOf: asOf)
    try await store.deleteExpired(asOf: asOf, batchSize: config.retentionBatchSize)
    guard let labelRefresher else { throw WireLabelQueryError.incompleteResponse }
    try await labelRefresher.refresh(asOf: asOf)

    let rankingPlans = config.externalSignalMode.generationPlans(baseline: config.ranking)
    let servingRanking = rankingPlans.first(where: \.activationEligible)?.config ?? config.ranking
    let localeBuckets =
      config.languageBucket == "und"
      ? try await store.eligibleLanguageBuckets(
        limit: 12,
        minimumCandidates: WireDataPolicy.minimumLocaleCandidates,
        ranking: servingRanking,
        asOf: asOf
      )
      : []
    let buckets = [config.languageBucket] + localeBuckets.filter { $0 != config.languageBucket }
    var primary: (id: UUID, count: Int, activated: Bool)?
    for bucket in buckets {
      let activationFloor =
        bucket == "und"
        ? WireDataPolicy.minimumGlobalCandidates
        : WireDataPolicy.minimumLocaleCandidates
      for plan in rankingPlans {
        let candidates = try await store.loadCandidates(
          languageBucket: bucket,
          limit: config.candidateLimit,
          ranking: plan.config,
          asOf: asOf
        )
        let result = try WireRanker.rank(candidates: candidates, asOf: asOf, config: plan.config)
        let generationID = UUID()
        let canFillFirstPage = result.items.count >= WireDataPolicy.diverseFirstPageCount
        let eligible = result.items.count >= activationFloor && canFillFirstPage
        let activate =
          plan.activationEligible
          && (config.mode == .api || config.mode == .visible)
          && eligible
        try await store.commit(
          WireGenerationCommit(
            generationID: generationID,
            feedKey: "wire",
            languageBucket: bucket,
            configVersion: plan.config.version,
            generatedAt: asOf,
            expiresAt: asOf.addingTimeInterval(Double(config.generationRetentionSeconds)),
            activate: activate,
            result: result
          )
        )
        if bucket == config.languageBucket, plan.activationEligible {
          primary = (generationID, result.items.count, activate)
        }
      }
    }
    guard let primary else { return .off }
    return .generated(id: primary.id, itemCount: primary.count, activated: primary.activated)
  }
}
