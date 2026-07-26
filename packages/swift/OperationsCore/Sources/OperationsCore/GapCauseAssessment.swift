import Foundation

public struct GapCauseAssessment: Codable, Sendable {
  public enum Confidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case insufficient
  }

  public let title: String
  public let confidence: Confidence
  public let summary: String
  public let evidenceIds: [String]
  public let limitations: [String]

  public init(
    title: String,
    confidence: Confidence,
    summary: String,
    evidenceIds: [String],
    limitations: [String]
  ) {
    self.title = title
    self.confidence = confidence
    self.summary = summary
    self.evidenceIds = evidenceIds
    self.limitations = limitations
  }
}
