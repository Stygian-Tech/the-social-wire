import WireCore

enum WireExternalSignalMode: String, CaseIterable, Sendable {
  case off
  case shadow
  case rank

  func generationPlans(baseline: WireRankingConfig) -> [WireRankingPlan] {
    switch self {
    case .off:
      return [WireRankingPlan(config: baseline, activationEligible: true)]
    case .shadow:
      return [
        WireRankingPlan(config: baseline, activationEligible: true),
        WireRankingPlan(config: .externalSignalsV11(), activationEligible: false),
      ]
    case .rank:
      return [WireRankingPlan(config: .externalSignalsV11(), activationEligible: true)]
    }
  }
}

struct WireRankingPlan: Equatable, Sendable {
  var config: WireRankingConfig
  var activationEligible: Bool
}
