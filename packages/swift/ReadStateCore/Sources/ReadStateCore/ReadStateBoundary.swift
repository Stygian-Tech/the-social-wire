import Foundation

public struct ReadStateBoundary: Codable, Sendable, Equatable {
  public let scope: ReadStateScope
  public let createdAt: String
  /// Omitted means inclusive timestamp, matching legacy AppView floors.
  public let entryId: String?

  public init(scope: ReadStateScope, createdAt: String, entryId: String?) {
    self.scope = scope
    self.createdAt = createdAt
    self.entryId = entryId
  }
}
