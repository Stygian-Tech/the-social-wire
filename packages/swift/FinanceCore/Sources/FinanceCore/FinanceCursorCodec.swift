import Crypto
import Foundation

public struct FinanceCursorCodec: Sendable {
  private let secret: Data
  public init(secret: Data) throws {
    guard secret.count >= 32 else { throw FinanceCursorError.invalidSecret }
    self.secret = secret
  }
  public init(secret: String) throws { try self.init(secret: Data(secret.utf8)) }
  public func encode(_ cursor: FinanceCursor) throws -> String {
    guard !cursor.feed.isEmpty, cursor.feed.utf8.count <= 256, cursor.nextOrdinal >= 0, !cursor.generationID.isEmpty,
      !cursor.language.isEmpty, !cursor.preferenceFingerprint.isEmpty, !cursor.viewerScope.isEmpty
    else { throw FinanceCursorError.invalidContext }
    let data = try JSONEncoder().encode(cursor)
    let signature = Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret)))
    return Self.base64(data) + "." + Self.base64(signature)
  }
  public func decode(_ encoded: String, language: String, preferenceFingerprint: String,
    viewerScope: String, now: Date = Date(), feed: String = "finance") throws -> FinanceCursor {
    guard encoded.utf8.count <= 4096 else { throw FinanceCursorError.malformed }
    let parts = encoded.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let data = Self.data(String(parts[0])), let signature = Self.data(String(parts[1]))
    else { throw FinanceCursorError.malformed }
    guard Self.base64(data) == String(parts[0]), Self.base64(signature) == String(parts[1]),
      HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: data, using: SymmetricKey(data: secret))
    else { throw FinanceCursorError.invalidSignature }
    guard let cursor = try? JSONDecoder().decode(FinanceCursor.self, from: data) else { throw FinanceCursorError.malformed }
    guard cursor.feed == feed, cursor.nextOrdinal >= 0, !cursor.generationID.isEmpty,
      cursor.language == language, cursor.preferenceFingerprint == preferenceFingerprint, cursor.viewerScope == viewerScope
    else { throw FinanceCursorError.invalidContext }
    guard cursor.expiresAt > now else { throw FinanceCursorError.expired }
    return cursor
  }
  private static func base64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  private static func data(_ string: String) -> Data? {
    var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    return Data(base64Encoded: value)
  }
}
