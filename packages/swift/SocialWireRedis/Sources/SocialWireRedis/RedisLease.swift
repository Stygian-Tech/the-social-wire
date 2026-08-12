import Foundation

public struct RedisLease: Sendable, Equatable {
  public let key: String
  public let owner: String
  public let ttlMilliseconds: Int

  public init(key: String, owner: String, ttlMilliseconds: Int) {
    self.key = key
    self.owner = owner
    self.ttlMilliseconds = ttlMilliseconds
  }
}
