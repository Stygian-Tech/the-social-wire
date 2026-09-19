import Foundation

/// Audit metadata for an exact selection; evaluation uses its frozen subject IDs.
public struct ReadStateCalendarSelection: Codable, Sendable, Equatable {
  public let cutoff: String
  public let timeZone: String
  public let referenceDate: String

  public init(cutoff: String, timeZone: String, referenceDate: String) {
    self.cutoff = cutoff
    self.timeZone = timeZone
    self.referenceDate = referenceDate
  }
}
