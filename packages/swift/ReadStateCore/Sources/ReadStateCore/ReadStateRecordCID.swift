import CoreFoundation
import Crypto
import Foundation

/// Bounded canonical DAG-CBOR encoding for JSON read-state records. Verify the
/// original JSON, including unknown fields, before decoding the typed record.
/// https://atproto.com/specs/data-model
public enum ReadStateRecordCID {
  public static func verify(json: Data, cid: String) throws {
    guard json.count <= ReadStateValidation.maximumRecordBytes else { throw ReadStateError.sizeLimit }
    let expected = try decodeCID(cid)
    guard expected.count == 36, Array(expected.prefix(4)) == [1, 0x71, 0x12, 0x20] else {
      throw ReadStateError.invalidReference
    }
    let value = try JSONSerialization.jsonObject(with: json)
    guard value is [String: Any] else { throw ReadStateError.invalidRecord }
    var bytes = Data()
    try encode(value, into: &bytes, depth: 0)
    guard Data(SHA256.hash(data: bytes)) == expected.suffix(32) else {
      throw ReadStateError.invalidReference
    }
  }

  private static func encode(_ value: Any, into bytes: inout Data, depth: Int) throws {
    guard depth <= 32 else { throw ReadStateError.sizeLimit }
    if let string = value as? String {
      let utf8 = Data(string.utf8)
      header(3, UInt64(utf8.count), into: &bytes)
      bytes.append(utf8)
    } else if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        bytes.append(number.boolValue ? 0xf5 : 0xf4)
      } else {
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else {
          throw ReadStateError.invalidRecord
        }
        let integer = Int64(value)
        header(integer >= 0 ? 0 : 1, UInt64(integer >= 0 ? integer : -1 - integer), into: &bytes)
      }
    } else if value is NSNull { bytes.append(0xf6)
    } else if let array = value as? [Any] {
      header(4, UInt64(array.count), into: &bytes)
      for value in array { try encode(value, into: &bytes, depth: depth + 1) }
    } else if let object = value as? [String: Any] {
      if object.count == 1, let link = object["$link"] as? String {
        let data = Data([0]) + (try decodeCID(link))
        header(6, 42, into: &bytes)
        header(2, UInt64(data.count), into: &bytes)
        bytes.append(data)
      } else if object.count == 1, let encoded = object["$bytes"] as? String {
        let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded + padding) else { throw ReadStateError.invalidRecord }
        header(2, UInt64(data.count), into: &bytes)
        bytes.append(data)
      } else {
        let keys = object.keys.sorted { left, right in
          left.utf8.count == right.utf8.count
            ? left.utf8.lexicographicallyPrecedes(right.utf8) : left.utf8.count < right.utf8.count
        }
        header(5, UInt64(keys.count), into: &bytes)
        for key in keys {
          try encode(key, into: &bytes, depth: depth + 1)
          try encode(object[key]!, into: &bytes, depth: depth + 1)
        }
      }
    } else { throw ReadStateError.invalidRecord }
    guard bytes.count <= ReadStateValidation.maximumRecordBytes else { throw ReadStateError.sizeLimit }
  }

  private static func header(_ major: UInt8, _ value: UInt64, into bytes: inout Data) {
    if value < 24 { bytes.append(major << 5 | UInt8(value)); return }
    let count: Int = value <= 255 ? 1 : value <= 65_535 ? 2 : value <= 4_294_967_295 ? 4 : 8
    let additional: UInt8 = count == 1 ? 24 : count == 2 ? 25 : count == 4 ? 26 : 27
    bytes.append(major << 5 | additional)
    for shift in stride(from: (count - 1) * 8, through: 0, by: -8) {
      bytes.append(UInt8(truncatingIfNeeded: value >> shift))
    }
  }

  private static func decodeCID(_ value: String) throws -> Data {
    guard value.first == "b", value.utf8.count == 59 else { throw ReadStateError.invalidReference }
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
    var buffer: UInt32 = 0
    var bits = 0
    var result = Data()
    for character in value.utf8.dropFirst() {
      guard let index = alphabet.firstIndex(of: character) else { throw ReadStateError.invalidReference }
      buffer = (buffer << 5) | UInt32(index)
      bits += 5
      if bits >= 8 {
        bits -= 8
        result.append(UInt8(truncatingIfNeeded: buffer >> bits))
        buffer &= (1 << bits) - 1
      }
    }
    guard buffer == 0, result.count == 36, result[0] == 1,
          [0x55, 0x71].contains(result[1]), result[2] == 0x12, result[3] == 0x20 else {
      throw ReadStateError.invalidReference
    }
    return result
  }
}
