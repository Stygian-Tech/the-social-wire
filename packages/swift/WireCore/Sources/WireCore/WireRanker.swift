import Foundation

public enum WireRanker {
  static let rotationInterval: TimeInterval = 1_800
  static let maximumRotationNudge = 0.005

  private enum AdmissionTier {
    case primary
    case breaking
    case qualityBackfill
  }

  private static let breakingMaximumAge: TimeInterval = 6 * 60 * 60
  private static let breakingMinimumShares1h = 3

  public static func rank(
    candidates: [WireCandidate],
    asOf: Date,
    config: WireRankingConfig
  ) throws -> WireRankingResult {
    try config.validate()

    var rejectedForAge = 0
    var rejectedForQuality = 0
    var rejectedForSignalFloor = 0
    var primary: [WireScoredCandidate] = []
    var qualityBackfill: [WireScoredCandidate] = []

    let signalEligible = candidates.filter { candidate in
      let age = max(0, asOf.timeIntervalSince(candidate.publishedAt ?? candidate.firstSeenAt))
      return admissionTier(for: candidate, age: age, config: config) != nil
    }
    let shareVelocityP90 = percentile(signalEligible.map(\.shares1h), quantile: 0.90)
    let sharersP90 = percentile(signalEligible.map(\.shares24h), quantile: 0.90)
    let communitiesP75 = percentile(signalEligible.map(\.communities24h), quantile: 0.75)

    for candidate in candidates {
      let publicationDate = candidate.publishedAt ?? candidate.firstSeenAt
      let age = max(0, asOf.timeIntervalSince(publicationDate))
      guard age <= config.maximumCandidateAge else {
        rejectedForAge += 1
        continue
      }
      guard candidate.sourceConfidence.isFinite,
        candidate.sourceConfidence >= config.minimumSourceConfidence
      else {
        rejectedForQuality += 1
        continue
      }
      guard candidate.targetKind.canCreateItem, candidate.commercialClass != .probableAd else {
        rejectedForQuality += 1
        continue
      }
      guard candidate.isStandardSite == true || candidate.hasUsableOpenGraphMetadata == true else {
        rejectedForQuality += 1
        continue
      }
      guard let tier = admissionTier(for: candidate, age: age, config: config) else {
        rejectedForSignalFloor += 1
        continue
      }

      let distinctSharers24h = logarithmicRatio(
        candidate.shares24h,
        target: config.actorBreadthTarget
      )
      let shareVelocity1h = velocity(hour: candidate.shares1h, day: candidate.shares24h)
      let likeBreadthVelocity = 0.5 * (
        logarithmicRatio(candidate.distinctLikes24h, target: config.actorBreadthTarget)
          + velocity(hour: candidate.likes1h, day: candidate.likes24h)
      )
      let repostBreadthVelocity = 0.5 * (
        logarithmicRatio(candidate.distinctReposts24h, target: config.actorBreadthTarget)
          + velocity(hour: candidate.reposts1h, day: candidate.reposts24h)
      )
      let communitySpread = clamp(
        Double(candidate.communities24h) / Double(config.communityBreadthTarget)
      )
      let freshness = pow(0.5, age / config.freshnessHalfLife)
      let sevenDayHourlyBaseline = max(1, Double(candidate.signals7d) / (7 * 24))
      let resurfacingAcceleration = clamp(
        Double(candidate.shares1h) / (sevenDayHourlyBaseline * 3)
      )
      let sourceConfidence = clamp(candidate.sourceConfidence)
      let standardSiteAuthority = candidate.isStandardSite == true ? 1.0 : 0.0
      let openGraphMetadata = candidate.hasUsableOpenGraphMetadata == true ? 1.0 : 0.0
      let recommendationBreadth = logarithmicRatio(
        candidate.recommendations24h,
        target: config.recommendationBreadthTarget
      )
      let positiveFeedbackBreadth = logarithmicRatio(
        candidate.positiveFeedback24h,
        target: config.feedbackBreadthTarget
      )
      let negativeFeedbackBreadth = logarithmicRatio(
        candidate.negativeFeedback24h,
        target: config.feedbackBreadthTarget
      )
      let weightTotal = config.weights.all.reduce(0, +)
      let positiveScore = (
        distinctSharers24h * config.weights.distinctSharers24h
          + shareVelocity1h * config.weights.shareVelocity1h
          + likeBreadthVelocity * config.weights.likeBreadthVelocity
          + repostBreadthVelocity * config.weights.repostBreadthVelocity
          + communitySpread * config.weights.communitySpread
          + freshness * config.weights.freshness
          + resurfacingAcceleration * config.weights.resurfacingAcceleration
          + sourceConfidence * config.weights.sourceConfidence
          + standardSiteAuthority * config.weights.standardSiteAuthority
          + openGraphMetadata * config.weights.openGraphMetadata
          + recommendationBreadth * config.weights.recommendationBreadth
          + positiveFeedbackBreadth * config.weights.positiveFeedbackBreadth
      ) / weightTotal
      let feedbackAdjustedScore = clamp(
        positiveScore - negativeFeedbackBreadth * config.weights.negativeFeedbackPenalty
      )
      let score = clamp(
        feedbackAdjustedScore - config.domainPenalties.penalty(for: candidate.sourceDomain)
          - (candidate.commercialClass == .limited ? config.limitedCommercialPenalty : 0)
          - (candidate.hasUsableThumbnail == true ? 0 : config.missingThumbnailPenalty)
          + rotationNudge(canonicalKey: candidate.canonicalKey, asOf: asOf)
      )

      guard score.isFinite else { continue }

      let scoredCandidate = WireScoredCandidate(
        candidate: candidate,
        score: score,
        reasonCodes: reasons(
          for: candidate,
          age: age,
          shareVelocityP90: shareVelocityP90,
          sharersP90: sharersP90,
          communitiesP75: communitiesP75
        )
      )
      switch tier {
      case .primary: primary.append(scoredCandidate)
      case .breaking: primary.append(scoredCandidate)
      case .qualityBackfill: qualityBackfill.append(scoredCandidate)
      }
    }

    func sort(_ values: inout [WireScoredCandidate]) {
      values.sort {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.candidate.canonicalKey < $1.candidate.canonicalKey
      }
    }
    sort(&primary)
    sort(&qualityBackfill)

    let qualityCount = min(
      qualityBackfill.count,
      max(0, config.minimumRankedItems - primary.count)
    )
    rejectedForSignalFloor += qualityBackfill.count - qualityCount
    let scored = primary
      + qualityBackfill.prefix(qualityCount)
    let diversity = WireDiversityReranker.rerank(scored, policy: config.diversity)
    return WireRankingResult(
      items: diversity.items,
      diagnostics: WireRankingDiagnostics(
        candidateCount: candidates.count,
        eligibleCount: scored.count,
        rejectedForAge: rejectedForAge,
        rejectedForQuality: rejectedForQuality,
        rejectedForSignalFloor: rejectedForSignalFloor,
        qualityBackfillCount: qualityCount,
        generalBackfillCount: 0,
        diversityDeferrals: diversity.interventions.count
      )
    )
  }

  private static func logarithmicRatio(_ value: Int, target: Int) -> Double {
    clamp(log1p(Double(max(0, value))) / log1p(Double(target)))
  }

  private static func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
  }

  static func rotationNudge(canonicalKey: String, asOf: Date) -> Double {
    let bucket = Int64(floor(asOf.timeIntervalSince1970 / rotationInterval))
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in "\(bucket)|\(canonicalKey)".utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Double(hash % 1_000_001) / 1_000_000 * maximumRotationNudge
  }

  private static func velocity(hour: Int, day: Int) -> Double {
    let expectedHourly = max(1, Double(max(0, day)) / 24)
    return clamp(Double(max(0, hour)) / (expectedHourly * 4))
  }

  private static func percentile(_ values: [Int], quantile: Double) -> Int {
    guard !values.isEmpty else { return .max }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * quantile)) - 1))
    return sorted[index]
  }

  private static func reasons(
    for candidate: WireCandidate,
    age: TimeInterval,
    shareVelocityP90: Int,
    sharersP90: Int,
    communitiesP75: Int
  ) -> [WireReasonCode] {
    var result: [WireReasonCode] = []
    if age <= 21_600, candidate.shares1h >= max(1, shareVelocityP90) {
      result.append(.breakingStory)
    }
    if candidate.shares24h >= max(1, sharersP90) { result.append(.widelyDiscussed) }
    if candidate.communities24h >= 3,
      candidate.communities24h >= max(1, communitiesP75)
    {
      result.append(.sharedAcrossCommunities)
    }
    if qualifiesFreshPublicationLane(candidate, age: age) {
      result.append(.freshPublication)
    }
    let baseline = max(1, Double(candidate.signals7d) / (7 * 24))
    if age >= 172_800, Double(candidate.shares1h) >= baseline * 3 {
      result.append(.resurfacing)
    }
    let priority: [WireReasonCode] = [
      .breakingStory, .widelyDiscussed, .sharedAcrossCommunities, .freshPublication, .resurfacing,
    ]
    return Array(priority.filter(result.contains).prefix(2))
  }

  private static func qualifiesFreshPublicationLane(
    _ candidate: WireCandidate,
    age: TimeInterval
  ) -> Bool {
    age <= 3 * 86_400
      && candidate.sourceConfidence >= 0.75
      && candidate.isStandardSite == true
  }

  private static func admissionTier(
    for candidate: WireCandidate,
    age: TimeInterval,
    config: WireRankingConfig
  ) -> AdmissionTier? {
    if age <= breakingMaximumAge,
      candidate.shares1h >= breakingMinimumShares1h,
      candidate.shares24h >= breakingMinimumShares1h
    {
      return .breaking
    }
    if candidate.shares24h >= config.minimumHighIntentActors
      || candidate.recommendations24h >= config.minimumRecommendations
      || (qualifiesFreshPublicationLane(candidate, age: age)
        && candidate.shares24h >= config.standardSiteMinimumHighIntentActors)
    {
      return .primary
    }
    guard candidate.shares24h >= config.backfillMinimumHighIntentActors
      || candidate.recommendations24h >= config.backfillMinimumRecommendations
    else { return nil }
    return .qualityBackfill
  }
}
