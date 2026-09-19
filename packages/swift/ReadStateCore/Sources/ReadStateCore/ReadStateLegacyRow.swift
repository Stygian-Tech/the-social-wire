import Foundation

/// Ordered baseline export: boundaries, then unread overrides, then explicit reads.
public struct ReadStateLegacyRow: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case boundary, read, unread }
  public let kind: Kind
  public let actedAt: String
  public let boundary: ReadStateBoundary?
  public let subjectUri: String?

  public init(kind: Kind, actedAt: String, boundary: ReadStateBoundary? = nil, subjectUri: String? = nil) {
    self.kind = kind
    self.actedAt = actedAt
    self.boundary = boundary
    self.subjectUri = subjectUri
  }
}
