import WireCore

public struct SportsRankCandidate: Codable, Equatable, Sendable {
  public let item: WireFeedItem
  public let analysis: SportsArticleAnalysis
  public let baseScore: Double
  public let majorGlobal: Bool
  public init(item: WireFeedItem, analysis: SportsArticleAnalysis, baseScore: Double, majorGlobal: Bool = false) {
    self.item = item; self.analysis = analysis; self.baseScore = baseScore; self.majorGlobal = majorGlobal
  }
}
