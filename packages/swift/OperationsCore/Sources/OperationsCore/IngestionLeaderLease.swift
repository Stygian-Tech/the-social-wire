import Foundation

public struct IngestionLeaderLease: Codable, Sendable, Equatable {
  public let environment: String
  public let name: String
  public let sourceGeneration: String
  public let ownerID: String
  public let fencingToken: Int64
  public let acquiredAt: Date
  public let expiresAt: Date
  public let updatedAt: Date
}
