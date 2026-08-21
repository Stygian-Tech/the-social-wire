import Foundation

public struct WireRankingConfig: Codable, Equatable, Sendable {
  public var version: String
  public var weights: WireRankingWeights
  public var diversity: WireDiversityPolicy
  public var minimumDistinctActors: Int
  public var minimumRecommendations: Int
  public var minimumSourceConfidence: Double
  public var actorBreadthTarget: Int
  public var communityBreadthTarget: Int
  public var engagementTarget: Int
  public var freshnessHalfLife: TimeInterval
  public var maximumCandidateAge: TimeInterval

  public init(
    version: String = "wire-v1",
    weights: WireRankingWeights = WireRankingWeights(),
    diversity: WireDiversityPolicy = WireDiversityPolicy(),
    minimumDistinctActors: Int = 3,
    minimumRecommendations: Int = 1,
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
    self.minimumDistinctActors = minimumDistinctActors
    self.minimumRecommendations = minimumRecommendations
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
    guard minimumDistinctActors >= 0, minimumRecommendations >= 0,
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
