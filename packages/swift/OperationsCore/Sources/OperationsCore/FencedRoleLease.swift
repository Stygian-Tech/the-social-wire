import Foundation

public struct FencedRoleLease: Codable, Sendable, Equatable {
  public let environment: String
  public let role: String
  public let ownerID: String
  public let fencingToken: Int64
  public let acquiredAt: Date
  public let expiresAt: Date
  public let updatedAt: Date

  public init(
    environment: String,
    role: String,
    ownerID: String,
    fencingToken: Int64,
    acquiredAt: Date,
    expiresAt: Date,
    updatedAt: Date
  ) {
    self.environment = environment
    self.role = role
    self.ownerID = ownerID
    self.fencingToken = fencingToken
    self.acquiredAt = acquiredAt
    self.expiresAt = expiresAt
    self.updatedAt = updatedAt
  }

  static func validate(role: String, ownerID: String) throws {
    guard !role.isEmpty, role.count <= 128, !ownerID.isEmpty, ownerID.count <= 255 else {
      throw OperationsStoreError.invalidProgress
    }
  }
}
