import Foundation

public struct CircleCursor: Equatable, Sendable {
  public let snapshotID: String
  public let generationID: String
  public let language: String
  public let nextOrdinal: Int
  public let expiresAt: Date

  public init(
    snapshotID: String,
    generationID: String,
    language: String,
    nextOrdinal: Int,
    expiresAt: Date
  ) {
    self.snapshotID = snapshotID
    self.generationID = generationID
    self.language = language
    self.nextOrdinal = nextOrdinal
    self.expiresAt = expiresAt
  }
}
