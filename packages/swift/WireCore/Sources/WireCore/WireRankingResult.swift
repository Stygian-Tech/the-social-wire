public struct WireRankingResult: Codable, Equatable, Sendable {
  public var items: [WireScoredCandidate]
  public var diagnostics: WireRankingDiagnostics

  public init(items: [WireScoredCandidate], diagnostics: WireRankingDiagnostics) {
    self.items = items
    self.diagnostics = diagnostics
  }
}
