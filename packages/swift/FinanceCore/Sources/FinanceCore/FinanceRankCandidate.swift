import WireCore

public struct FinanceRankCandidate: Codable, Equatable, Sendable {
  public let item: WireFeedItem
  public let analysis: FinanceArticleAnalysis
  public let baseScore: Double
  public let majorGlobal: Bool
  public init(item: WireFeedItem, analysis: FinanceArticleAnalysis, baseScore: Double, majorGlobal: Bool = false) {
    self.item = item; self.analysis = analysis; self.baseScore = baseScore; self.majorGlobal = majorGlobal
  }
}
