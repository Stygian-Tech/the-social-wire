import Foundation

public struct WireRankingConfig: Codable, Equatable, Sendable {
  public static let baselineVersion = "wire-v10"
  public static let externalSignalVersion = "wire-v11"

  public var version: String
  public var weights: WireRankingWeights
  public var diversity: WireDiversityPolicy
  public var minimumHighIntentActors: Int
  public var minimumRecommendations: Int
  public var standardSiteMinimumHighIntentActors: Int
  public var backfillMinimumHighIntentActors: Int
  public var backfillMinimumRecommendations: Int
  public var minimumRankedItems: Int
  public var minimumSourceConfidence: Double
  public var standardSiteMinimumSourceConfidence: Double
  public var actorBreadthTarget: Int
  public var recommendationBreadthTarget: Int
  public var feedbackBreadthTarget: Int
  public var communityBreadthTarget: Int
  public var engagementTarget: Int
  public var freshnessHalfLife: TimeInterval
  public var maximumCandidateAge: TimeInterval
  public var domainPenalties: WireDomainPenaltyPolicy
  public var limitedCommercialPenalty: Double
  public var missingThumbnailPenalty: Double

  public init(
    version: String = WireRankingConfig.baselineVersion,
    weights: WireRankingWeights = WireRankingWeights(),
    diversity: WireDiversityPolicy = WireDiversityPolicy(),
    minimumHighIntentActors: Int = 5,
    minimumRecommendations: Int = 2,
    standardSiteMinimumHighIntentActors: Int = 1,
    backfillMinimumHighIntentActors: Int = 3,
    backfillMinimumRecommendations: Int = 1,
    minimumRankedItems: Int = 50,
    minimumSourceConfidence: Double = 0.25,
    standardSiteMinimumSourceConfidence: Double = 0.75,
    actorBreadthTarget: Int = 30,
    recommendationBreadthTarget: Int = 10,
    feedbackBreadthTarget: Int = 10,
    communityBreadthTarget: Int = 5,
    engagementTarget: Int = 80,
    freshnessHalfLife: TimeInterval = 36_000,
    maximumCandidateAge: TimeInterval = 2_592_000,
    domainPenalties: WireDomainPenaltyPolicy = WireDomainPenaltyPolicy(),
    limitedCommercialPenalty: Double = 0.15,
    missingThumbnailPenalty: Double = 0.15
  ) {
    self.version = version
    self.weights = weights
    self.diversity = diversity
    self.minimumHighIntentActors = minimumHighIntentActors
    self.minimumRecommendations = minimumRecommendations
    self.standardSiteMinimumHighIntentActors = standardSiteMinimumHighIntentActors
    self.backfillMinimumHighIntentActors = backfillMinimumHighIntentActors
    self.backfillMinimumRecommendations = backfillMinimumRecommendations
    self.minimumRankedItems = minimumRankedItems
    self.minimumSourceConfidence = minimumSourceConfidence
    self.standardSiteMinimumSourceConfidence = standardSiteMinimumSourceConfidence
    self.actorBreadthTarget = actorBreadthTarget
    self.recommendationBreadthTarget = recommendationBreadthTarget
    self.feedbackBreadthTarget = feedbackBreadthTarget
    self.communityBreadthTarget = communityBreadthTarget
    self.engagementTarget = engagementTarget
    self.freshnessHalfLife = freshnessHalfLife
    self.maximumCandidateAge = maximumCandidateAge
    self.domainPenalties = domainPenalties
    self.limitedCommercialPenalty = limitedCommercialPenalty
    self.missingThumbnailPenalty = missingThumbnailPenalty
  }

  public static func externalSignalsV11() -> WireRankingConfig {
    WireRankingConfig(version: externalSignalVersion)
  }

  public func validate() throws {
    guard [Self.baselineVersion, Self.externalSignalVersion].contains(version) else {
      throw WireRankingConfigError.invalidVersion
    }
    guard weights.all.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      throw WireRankingConfigError.invalidWeight
    }
    guard weights.all.reduce(0, +) > 0 else {
      throw WireRankingConfigError.zeroWeightTotal
    }
    guard minimumHighIntentActors >= 0, minimumRecommendations >= 0,
      standardSiteMinimumHighIntentActors >= 0,
      backfillMinimumHighIntentActors >= 0, backfillMinimumRecommendations >= 0,
      minimumRankedItems > 0,
      minimumSourceConfidence.isFinite, (0...1).contains(minimumSourceConfidence),
      standardSiteMinimumSourceConfidence.isFinite,
      (0...1).contains(standardSiteMinimumSourceConfidence),
      actorBreadthTarget > 0, recommendationBreadthTarget > 0, feedbackBreadthTarget > 0,
      communityBreadthTarget > 0, engagementTarget > 0,
      freshnessHalfLife > 0, maximumCandidateAge > 0,
      weights.negativeFeedbackPenalty.isFinite,
      weights.negativeFeedbackPenalty >= 0,
      weights.negativeFeedbackPenalty <= 1,
      limitedCommercialPenalty.isFinite,
      (0...1).contains(limitedCommercialPenalty),
      missingThumbnailPenalty.isFinite,
      (0...1).contains(missingThumbnailPenalty)
    else {
      throw WireRankingConfigError.invalidThreshold
    }
    try domainPenalties.validate()
    guard diversity.allCaps.allSatisfy({ $0 > 0 }) else {
      throw WireRankingConfigError.invalidDiversityCap
    }
  }
}
