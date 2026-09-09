import Foundation

public struct ReadStateOperation: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable { case read, unread }
  public enum Selection: String, Codable, Sendable { case boundaries, exact }

  public let actionId: String
  /// Assigned against the current manifest, not a device wall clock.
  public let sequence: Int64
  public let state: State
  public let actedAt: String
  public let selection: Selection
  public let boundaries: [ReadStateBoundary]?
  public let subjectUris: [String]?
  public let calendar: ReadStateCalendarSelection?

  public init(actionId: String, sequence: Int64, state: State, actedAt: String,
              boundaries: [ReadStateBoundary]) {
    self.actionId = actionId
    self.sequence = sequence
    self.state = state
    self.actedAt = actedAt
    selection = .boundaries
    self.boundaries = boundaries
    subjectUris = nil
    calendar = nil
  }

  public init(actionId: String, sequence: Int64, state: State, actedAt: String,
              subjectUris: [String], calendar: ReadStateCalendarSelection? = nil) {
    self.actionId = actionId
    self.sequence = sequence
    self.state = state
    self.actedAt = actedAt
    selection = .exact
    boundaries = nil
    self.subjectUris = subjectUris
    self.calendar = calendar
  }
}
