import Crypto
import Foundation

public struct CircleCursorCodec: Sendable {
  private struct Payload: Codable {
    let version: Int
    let viewer: String
    let snapshot: String
    let generation: String
    let language: String
    let nextOrdinal: Int
    let expiresAt: Int64
  }

  private let secret: Data

  public init(secret: Data) throws {
    guard secret.count >= 32 else { throw CircleCursorError.invalidSecret }
    self.secret = secret
  }

  public init(secret: String) throws {
    try self.init(secret: Data(secret.utf8))
  }

  public func encode(_ cursor: CircleCursor, viewerID: String) throws -> String {
    try Self.validate(cursor)
    let viewer = try viewerBinding(viewerID)
    let payload = try JSONEncoder().encode(
      Payload(
        version: 1,
        viewer: viewer,
        snapshot: cursor.snapshotID,
        generation: cursor.generationID,
        language: cursor.language,
        nextOrdinal: cursor.nextOrdinal,
        expiresAt: Int64(cursor.expiresAt.timeIntervalSince1970.rounded(.down))
      )
    )
    let signature = Data(
      HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: secret))
    )
    return "\(Self.base64URL(payload)).\(Self.base64URL(signature))"
  }

  public func decode(
    _ encoded: String,
    viewerID: String,
    now: Date = Date()
  ) throws -> CircleCursor {
    guard !encoded.isEmpty, encoded.utf8.count <= 4_096 else {
      throw CircleCursorError.malformed
    }
    let parts = encoded.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
      let payloadData = Self.decodeBase64URL(String(parts[0])),
      let signatureData = Self.decodeBase64URL(String(parts[1]))
    else { throw CircleCursorError.malformed }
    guard Self.base64URL(payloadData) == String(parts[0]),
      Self.base64URL(signatureData) == String(parts[1])
    else { throw CircleCursorError.invalidSignature }
    guard
      HMAC<SHA256>.isValidAuthenticationCode(
        signatureData,
        authenticating: payloadData,
        using: SymmetricKey(data: secret)
      )
    else { throw CircleCursorError.invalidSignature }

    let payload: Payload
    do {
      payload = try JSONDecoder().decode(Payload.self, from: payloadData)
    } catch {
      throw CircleCursorError.malformed
    }
    guard payload.version == 1 else { throw CircleCursorError.unsupportedVersion }
    guard payload.viewer == (try viewerBinding(viewerID)) else {
      throw CircleCursorError.viewerMismatch
    }
    let cursor = CircleCursor(
      snapshotID: payload.snapshot,
      generationID: payload.generation,
      language: payload.language,
      nextOrdinal: payload.nextOrdinal,
      expiresAt: Date(timeIntervalSince1970: TimeInterval(payload.expiresAt))
    )
    try Self.validate(cursor)
    guard cursor.expiresAt > now else { throw CircleCursorError.expired }
    return cursor
  }

  public func viewerBinding(_ viewerID: String) throws -> String {
    let normalized = viewerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty, normalized.utf8.count <= 2_048 else {
      throw CircleCursorError.invalidPayload
    }
    let input = Data("circle-viewer-v1\n\(normalized)".utf8)
    let digest = Data(
      HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret))
    )
    return "cv1:\(Self.base64URL(digest))"
  }

  private static func validate(_ cursor: CircleCursor) throws {
    guard cursor.nextOrdinal >= 0,
      !cursor.snapshotID.isEmpty, cursor.snapshotID.utf8.count <= 128,
      !cursor.generationID.isEmpty, cursor.generationID.utf8.count <= 128,
      !cursor.language.isEmpty, cursor.language.utf8.count <= 35,
      cursor.expiresAt.timeIntervalSince1970.isFinite,
      cursor.expiresAt.timeIntervalSince1970 > 0
    else { throw CircleCursorError.invalidPayload }
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
