import Foundation

/// Preserves extension fields while updating the manifest's known fields.
public enum ReadStateJSONValue: Codable, Sendable, Equatable {
  case null, boolean(Bool), integer(Int64), string(String)
  case array([ReadStateJSONValue]), object([String: ReadStateJSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
    else if let value = try? container.decode(Int64.self) { self = .integer(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([ReadStateJSONValue].self) { self = .array(value) }
    else { self = .object(try container.decode([String: ReadStateJSONValue].self)) }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .boolean(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}
