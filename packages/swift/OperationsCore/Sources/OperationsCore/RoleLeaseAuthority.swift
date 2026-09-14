import Foundation

/// Identity of an authority grant. Validate it in the transaction that publishes its work.
public struct RoleLeaseAuthority: Sendable, Equatable {
  public let environment: String
  public let role: String
  public let ownerID: String
  public let fencingToken: Int64

  public init(environment: String, role: String, ownerID: String, fencingToken: Int64) {
    self.environment = environment
    self.role = role
    self.ownerID = ownerID
    self.fencingToken = fencingToken
  }
}
