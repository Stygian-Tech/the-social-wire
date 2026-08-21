import Crypto
import Foundation

public struct WireCursorCodec: Sendable {
  private struct Payload: Codable {
    let version: Int
    let generation: String
    let language: String
    let nextOrdinal: Int
  }

  private let secret: Data

  public init(secret: Data) throws {
    guard secret.count >= 32 else { throw WireCursorError.invalidSecret }
    self.secret = secret
  }

  public init(secret: String) throws {
    try self.init(secret: Data(secret.utf8))
  }

  public func encode(_ cursor: WireCursor) throws -> String {
    try Self.validate(cursor)
    let payload = try JSONEncoder().encode(
      Payload(
        version: 1,
        generation: cursor.generationID,
        language: cursor.language,
        nextOrdinal: cursor.nextOrdinal
      )
    )
    let signature = Data(
      HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: secret))
    )
    return "\(Self.base64URL(payload)).\(Self.base64URL(signature))"
  }

  public func decode(_ encoded: String) throws -> WireCursor {
    guard !encoded.isEmpty, encoded.utf8.count <= 4_096 else { throw WireCursorError.malformed }
    let parts = encoded.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
      let payloadData = Self.decodeBase64URL(String(parts[0])),
      let signatureData = Self.decodeBase64URL(String(parts[1]))
    else {
      throw WireCursorError.malformed
    }
    guard Self.base64URL(payloadData) == String(parts[0]),
      Self.base64URL(signatureData) == String(parts[1])
    else { throw WireCursorError.invalidSignature }
    guard HMAC<SHA256>.isValidAuthenticationCode(
      signatureData,
      authenticating: payloadData,
      using: SymmetricKey(data: secret)
    ) else {
      throw WireCursorError.invalidSignature
    }
    let payload: Payload
    do {
      payload = try JSONDecoder().decode(Payload.self, from: payloadData)
    } catch {
      throw WireCursorError.malformed
    }
    guard payload.version == 1 else { throw WireCursorError.unsupportedVersion }
    let cursor = WireCursor(
      generationID: payload.generation,
      language: payload.language,
      nextOrdinal: payload.nextOrdinal
    )
    try Self.validate(cursor)
    return cursor
  }

  private static func validate(_ cursor: WireCursor) throws {
    guard cursor.nextOrdinal >= 0,
      !cursor.generationID.isEmpty, cursor.generationID.utf8.count <= 128,
      !cursor.language.isEmpty, cursor.language.utf8.count <= 35
    else {
      throw WireCursorError.invalidPayload
    }
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    return Data(base64Encoded: base64)
  }
}
