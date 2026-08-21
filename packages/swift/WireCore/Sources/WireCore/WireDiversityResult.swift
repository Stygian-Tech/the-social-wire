public struct WireDiversityResult: Equatable, Sendable {
  public var items: [WireScoredCandidate]
  public var interventions: [WireDiversityIntervention]

  public init(items: [WireScoredCandidate], interventions: [WireDiversityIntervention]) {
    self.items = items
    self.interventions = interventions
  }
}
