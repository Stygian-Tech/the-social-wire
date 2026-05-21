import Crypto
import Foundation

/// Lightweight helpers for inspecting compact JWS payloads after signature verification succeeds elsewhere.
public enum CompactJWT {
  enum DecodeError: Swift.Error {
    case malformedSegmentCount
    case invalidPayloadJSON
  }

  static func decodePayloadJSON(from jwt: String) throws -> [String: Any] {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw DecodeError.malformedSegmentCount }
    guard let obj = try? PayloadJSON.decodeObject(base64URL: String(parts[1])) else {
      throw DecodeError.invalidPayloadJSON
    }
    return obj
  }
}

private enum PayloadJSON {
  static func decodeObject(base64URL: String) throws -> [String: Any] {
    let data = try Base64URL.decode(base64URL)
    return try decodeObject(data: data)
  }

  static func decodeObject(data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Base64URLDecodingError.invalidJSONPayload
    }
    return obj
  }
}

public enum Base64URLDecodingError: Swift.Error {
  case invalidAlphabetLength
  case invalidJSONPayload
}

public enum Base64URL {
  static func decode(_ value: String) throws -> Data {
    var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let mod = padded.count % 4
    if mod != 0 { padded.append(String(repeating: "=", count: 4 - mod)) }
    guard let data = Data(base64Encoded: padded) else { throw Base64URLDecodingError.invalidAlphabetLength }
    return data
  }

  /// Base64URL without padding — used for JWT signatures and **`ath`** digests per RFC 9449.
  static func encodeNoPadding<D: Digest>(digest: D) -> String {
    encodeNoPadding(data: digest.withUnsafeBytes { Data($0) })
  }

  static func encodeNoPadding(data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

public enum AccessTokenAth {
  static func expectedAth(accessTokenJWT: String) -> String {
    let digest = SHA256.hash(data: Data(accessTokenJWT.utf8))
    return Base64URL.encodeNoPadding(digest: digest)
  }
}
