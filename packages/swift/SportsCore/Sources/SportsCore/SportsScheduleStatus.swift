import Foundation

/// Distinguishes a successful empty schedule from missing or unsupported provider coverage.
public struct SportsScheduleStatus: Codable, Equatable, Sendable {
  public let competitionID: String
  public let status: String
  public let updatedAt: Date
  public init(competitionID: String, status: String, updatedAt: Date) {
    self.competitionID = competitionID; self.status = status; self.updatedAt = updatedAt
  }
}
