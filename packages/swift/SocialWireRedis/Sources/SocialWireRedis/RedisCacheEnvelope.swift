import Foundation

public struct RedisCacheEnvelope<Value: Codable & Sendable>: Codable, Sendable {
  public static var currentSchemaVersion: Int { 1 }

  public let schemaVersion: Int
  public let cachedAt: Date
  public let freshUntil: Date
  public let hardExpiresAt: Date
  public let value: Value

  public init(
    value: Value,
    cachedAt: Date,
    freshUntil: Date,
    hardExpiresAt: Date,
    schemaVersion: Int = Self.currentSchemaVersion
  ) {
    self.schemaVersion = schemaVersion
    self.cachedAt = cachedAt
    self.freshUntil = freshUntil
    self.hardExpiresAt = hardExpiresAt
    self.value = value
  }
}
