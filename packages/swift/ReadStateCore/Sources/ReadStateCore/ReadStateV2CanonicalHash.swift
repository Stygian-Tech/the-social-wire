import Crypto
import Foundation

/// Restricted DAG-CBOR for v2 intent/receipt values, without links, floats or lossy JSON bridges.
enum ReadStateV2CanonicalHash {
  static func hash(_ value: ReadStateJSONValue) throws -> String {
    SHA256.hash(data: try bytes(value)).map { String(format: "%02x", $0) }.joined()
  }
  static func key(_ value: ReadStateJSONValue) throws -> String {
    try bytes(value).map { String(format: "%02x", $0) }.joined()
  }
  static func value<T: Encodable>(_ value: T) throws -> ReadStateJSONValue {
    try JSONDecoder().decode(ReadStateJSONValue.self, from: JSONEncoder().encode(value))
  }
  static func bytes(_ value: ReadStateJSONValue) throws -> Data {
    var data = Data()
    func header(_ major: UInt8, _ value: UInt64) {
      if value < 24 { data.append(major << 5 | UInt8(value)); return }
      let count = value <= 255 ? 1 : value <= 65535 ? 2 : value <= 4294967295 ? 4 : 8
      data.append(major << 5 | (count == 1 ? 24 : count == 2 ? 25 : count == 4 ? 26 : 27))
      for shift in stride(from: (count - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    func append(_ value: ReadStateJSONValue, depth: Int) throws {
      guard depth <= 32 else { throw ReadStateError.sizeLimit }
      switch value {
      case .null: data.append(0xf6)
      case .boolean(let flag): data.append(flag ? 0xf5 : 0xf4)
      case .integer(let integer):
        guard (-ReadStateValidation.maximumSequence...ReadStateValidation.maximumSequence).contains(integer) else { throw ReadStateError.invalidRecord }
        header(integer < 0 ? 1 : 0, UInt64(integer < 0 ? -1 - integer : integer))
      case .string(let string): header(3, UInt64(string.utf8.count)); data.append(contentsOf: string.utf8)
      case .array(let values):
        header(4, UInt64(values.count)); for value in values { try append(value, depth: depth + 1) }
      case .object(let values):
        header(5, UInt64(values.count))
        for key in values.keys.sorted(by: { $0.utf8.count == $1.utf8.count ? $0.utf8.lexicographicallyPrecedes($1.utf8) : $0.utf8.count < $1.utf8.count }) {
          try append(.string(key), depth: depth + 1); try append(values[key]!, depth: depth + 1)
        }
      }
      guard data.count <= 16 * 1024 * 1024 else { throw ReadStateError.sizeLimit }
    }
    try append(value, depth: 0); return data
  }
}
