import Foundation
import SocialWireRedis

actor CircleRedisTestCommands: RedisCommandClient {
  enum Failure: Error { case unavailable, unsupported }
  private var data: [String: Data] = [:]
  private var ttl: [String: Int] = [:]
  private var unavailable = false

  func setUnavailable(_ value: Bool) { unavailable = value }
  func keys() -> [String] { Array(data.keys) }
  func expirations() -> [Int] { Array(ttl.values) }
  func get(_ key: String) throws -> Data? {
    if unavailable { throw Failure.unavailable }
    return data[key]
  }
  func set(_ key: String, value: Data, expirationMilliseconds: Int) throws {
    if unavailable { throw Failure.unavailable }
    data[key] = value
    ttl[key] = expirationMilliseconds
  }
  func setIfAbsent(_ key: String, value: Data, expirationMilliseconds: Int) throws -> Bool {
    guard data[key] == nil else { return false }
    try set(key, value: value, expirationMilliseconds: expirationMilliseconds)
    return true
  }
  func delete(_ keys: [String]) throws -> Int {
    if unavailable { throw Failure.unavailable }
    var count = 0
    for key in keys {
      if data.removeValue(forKey: key) != nil { count += 1 }
      ttl.removeValue(forKey: key)
    }
    return count
  }
  func execute(command: String, arguments: [RedisCommandValue]) throws -> RedisCommandValue {
    throw Failure.unsupported
  }
  func ping() throws { if unavailable { throw Failure.unavailable } }
  func shutdown() {}
}
