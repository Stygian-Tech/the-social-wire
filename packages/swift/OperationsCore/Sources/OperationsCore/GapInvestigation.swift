import Foundation

public struct GapInvestigation: Codable, Sendable {
  public let gap: IngestionGap
  public let windowStart: Date
  public let windowEnd: Date
  public let assessment: GapCauseAssessment
  public let evidence: [GapInvestigationEvidence]
  public let recommendedActions: [String]

  public init(
    gap: IngestionGap,
    windowStart: Date,
    windowEnd: Date,
    assessment: GapCauseAssessment,
    evidence: [GapInvestigationEvidence],
    recommendedActions: [String]
  ) {
    self.gap = gap
    self.windowStart = windowStart
    self.windowEnd = windowEnd
    self.assessment = assessment
    self.evidence = evidence
    self.recommendedActions = recommendedActions
  }
}
