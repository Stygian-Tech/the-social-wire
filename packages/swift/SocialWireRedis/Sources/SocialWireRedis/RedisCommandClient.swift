import Foundation

public protocol RedisCommandClient: Actor {
  func get(_ key: String) async throws -> Data?
  func set(_ key: String, value: Data, expirationMilliseconds: Int) async throws
  func setIfAbsent(
    _ key: String,
    value: Data,
    expirationMilliseconds: Int
  ) async throws -> Bool
  func delete(_ keys: [String]) async throws -> Int
  func execute(command: String, arguments: [RedisCommandValue]) async throws -> RedisCommandValue
  func ping() async throws
  func shutdown() async throws
}
