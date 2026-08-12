import Foundation

public enum RedisCommandValue: Sendable, Equatable {
  case null
  case data(Data)
  case integer(Int)
  case array([RedisCommandValue])

  public var string: String? {
    guard case .data(let data) = self else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
