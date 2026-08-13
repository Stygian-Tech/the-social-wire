import Foundation
@testable import SocialWireRedis

actor InMemoryRedisCommandClient: RedisCommandClient {
  private var values: [String: Data] = [:]
  private var sortedSets: [String: [String: Double]] = [:]
  private(set) var hasExpiry = false

  func get(_ key: String) async throws -> Data? { values[key] }

  func set(_ key: String, value: Data, expirationMilliseconds: Int) async throws {
    values[key] = value
  }

  func setIfAbsent(
    _ key: String,
    value: Data,
    expirationMilliseconds: Int
  ) async throws -> Bool {
    guard values[key] == nil else { return false }
    values[key] = value
    return true
  }

  func delete(_ keys: [String]) async throws -> Int {
    keys.reduce(into: 0) { count, key in
      if values.removeValue(forKey: key) != nil { count += 1 }
      if sortedSets.removeValue(forKey: key) != nil { count += 1 }
    }
  }

  func execute(command: String, arguments: [RedisCommandValue]) async throws -> RedisCommandValue {
    switch command {
    case "EVAL":
      guard arguments.count >= 4,
            let key = arguments[2].string,
            let owner = arguments[3].string,
            values[key] == Data(owner.utf8)
      else { return .integer(0) }
      if arguments.count == 4 {
        values.removeValue(forKey: key)
      }
      return .integer(1)
    case "ZADD":
      guard let key = arguments.first?.string else { return .integer(0) }
      var set = sortedSets[key] ?? [:]
      for index in stride(from: 1, to: arguments.count, by: 2) {
        guard index + 1 < arguments.count,
              let scoreText = arguments[index].string,
              let score = Double(scoreText),
              let member = arguments[index + 1].string
        else { continue }
        set[member] = score
      }
      sortedSets[key] = set
      return .integer(set.count)
    case "ZREVRANGE":
      guard let key = arguments.first?.string else { return .array([]) }
      let limit = (arguments[2].integerValue ?? -1) + 1
      let ordered = (sortedSets[key] ?? [:]).sorted {
        $0.value == $1.value ? $0.key > $1.key : $0.value > $1.value
      }.prefix(max(0, limit))
      return .array(ordered.flatMap { [.data(Data($0.key.utf8)), .data(Data($0.value.description.utf8))] })
    case "ZREM":
      guard let key = arguments.first?.string else { return .integer(0) }
      var set = sortedSets[key] ?? [:]
      var removed = 0
      for member in arguments.dropFirst().compactMap(\.string) {
        if set.removeValue(forKey: member) != nil { removed += 1 }
      }
      sortedSets[key] = set
      return .integer(removed)
    case "ZREMRANGEBYRANK":
      guard let key = arguments.first?.string,
            arguments.count >= 3,
            case .integer(let stop) = arguments[2]
      else { return .integer(0) }
      let ordered = (sortedSets[key] ?? [:]).sorted {
        $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
      }
      let inclusiveStop = stop < 0 ? max(-1, ordered.count + stop) : min(stop, ordered.count - 1)
      guard inclusiveStop >= 0 else { return .integer(0) }
      var set = sortedSets[key] ?? [:]
      for item in ordered[0...inclusiveStop] { set.removeValue(forKey: item.key) }
      sortedSets[key] = set
      return .integer(inclusiveStop + 1)
    case "PEXPIRE":
      hasExpiry = true
      return .integer(1)
    default:
      return .null
    }
  }

  func ping() async throws {}
  func shutdown() async throws {}
}

private extension RedisCommandValue {
  var integerValue: Int? {
    guard case .integer(let value) = self else { return nil }
    return value
  }
}
