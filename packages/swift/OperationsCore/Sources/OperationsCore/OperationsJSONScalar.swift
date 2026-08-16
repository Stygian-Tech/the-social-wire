import Foundation

/// A JSON scalar encoded as its original primitive value rather than as a tagged enum.
public enum OperationsJSONScalar: Codable, Sendable, Equatable {
  case string(String)
  case boolean(Bool)
  case integer(Int64)
  case number(Double)
  case null

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self), value.isFinite {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Expected a JSON string, boolean, number, or null.")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .boolean(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}
