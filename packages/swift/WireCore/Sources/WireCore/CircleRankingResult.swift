public struct CircleRankingResult: Equatable, Sendable {
  public let items: [CircleRankedCandidate]
  public let diagnostics: CircleRankingDiagnostics

  public init(items: [CircleRankedCandidate], diagnostics: CircleRankingDiagnostics) {
    self.items = items
    self.diagnostics = diagnostics
  }
}
