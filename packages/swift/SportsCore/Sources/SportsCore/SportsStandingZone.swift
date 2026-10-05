import Foundation

/// A current table position, not a claim that a club has secured an outcome.
public struct SportsStandingZone: Codable, Equatable, Sendable {
  public let kind: String
  public let label: String
  public let sourceURL: String
  public init(kind: String, label: String, sourceURL: String) {
    self.kind = kind; self.label = label; self.sourceURL = sourceURL
  }
}
