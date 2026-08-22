import Foundation

public struct WireRankingConfig: Codable, Equatable, Sendable {
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
  public var actorBreadthTarget: Int
  public var communityBreadthTarget: Int
  public var engagementTarget: Int
  public var freshnessHalfLife: TimeInterval
  public var maximumCandidateAge: TimeInterval

  public init(
    version: String = "wire-v2",
    weights: WireRankingWeights = WireRankingWeights(),
    diversity: WireDiversityPolicy = WireDiversityPolicy(),
    minimumHighIntentActors: Int = 5,
    minimumRecommendations: Int = 2,
    standardSiteMinimumHighIntentActors: Int = 3,
    backfillMinimumHighIntentActors: Int = 3,
    backfillMinimumRecommendations: Int = 1,
    minimumRankedItems: Int = 50,
    minimumSourceConfidence: Double = 0.25,
    actorBreadthTarget: Int = 30,
    communityBreadthTarget: Int = 5,
    engagementTarget: Int = 80,
    freshnessHalfLife: TimeInterval = 64_800,
    maximumCandidateAge: TimeInterval = 2_592_000
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
    self.actorBreadthTarget = actorBreadthTarget
    self.communityBreadthTarget = communityBreadthTarget
    self.engagementTarget = engagementTarget
    self.freshnessHalfLife = freshnessHalfLife
    self.maximumCandidateAge = maximumCandidateAge
  }

  public func validate() throws {
    guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
      actorBreadthTarget > 0, communityBreadthTarget > 0, engagementTarget > 0,
      freshnessHalfLife > 0, maximumCandidateAge > 0
    else {
      throw WireRankingConfigError.invalidThreshold
    }
    guard diversity.allCaps.allSatisfy({ $0 > 0 }) else {
      throw WireRankingConfigError.invalidDiversityCap
    }
  }
}
