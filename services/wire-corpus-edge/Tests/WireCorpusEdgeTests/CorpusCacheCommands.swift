import Foundation
import SocialWireRedis

actor CorpusCacheCommands: RedisCommandClient {
  enum Failure: Error { case unavailable }
  private var values: [String: Data] = [:]
  private var unavailable = false
  private(set) var writes = 0
  private(set) var expirations: [Int] = []
  func fail(_ value: Bool) { unavailable = value }
  func flush() { values.removeAll() }
  func keys() -> [String] { Array(values.keys) }
  func get(_ key: String) async throws -> Data? {
    if unavailable { throw Failure.unavailable }
    return values[key]
  }
  func set(_ key: String, value: Data, expirationMilliseconds: Int) async throws {
    if unavailable { throw Failure.unavailable }
    values[key] = value
    writes += 1
    expirations.append(expirationMilliseconds)
  }
  func setIfAbsent(_ key: String, value: Data, expirationMilliseconds: Int) async throws -> Bool {
    if values[key] != nil { return false }
    try await set(key, value: value, expirationMilliseconds: expirationMilliseconds)
    return true
  }
  func delete(_ keys: [String]) async throws -> Int {
    var deleted = 0
    for key in keys where values.removeValue(forKey: key) != nil { deleted += 1 }
    return deleted
  }
  func execute(command: String, arguments: [RedisCommandValue]) async throws -> RedisCommandValue { .null }
  func ping() async throws {}
  func shutdown() async throws {}
}
