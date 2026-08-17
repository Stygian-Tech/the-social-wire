import Crypto
import Foundation

/// Short-lived proof that this exact access token was recently attested against its authoritative PDS.
public struct ATProtoSessionAttestationReceipt: Sendable {
  public static let receiptHeaderName = "X-ATProto-Session-Attestation-Receipt"
  public static let requiredHeaderName = "X-ATProto-Session-Attestation-Required"
  public static let upstreamPreparedHeaderName = "X-ATProto-Upstream-DPoP-Prepared"

  static let maximumReceiptBytes = 4 * 1024
  static let maximumLifetime: TimeInterval = 60

  enum Error: Swift.Error, Sendable, Equatable {
    case invalidSecret
    case invalid
    case expired
  }

  struct VerifiedClaims: Sendable, Equatable {
    let did: String
    let cnfJkt: String
    let issuedAt: Date
    let validUntil: Date
  }

  private struct Claims: Codable, Sendable {
    let version: Int
    let keyId: String
    let issuedAt: Int64
    let validUntil: Int64
    let accessTokenHash: String
    let did: String
    let cnfJkt: String

    enum CodingKeys: String, CodingKey {
      case version = "v"
      case keyId = "kid"
      case issuedAt = "iat"
      case validUntil = "exp"
      case accessTokenHash = "ath"
      case did = "sub"
      case cnfJkt = "jkt"
    }
  }

  private let key: SymmetricKey
  private let keyId: String

  public init(secret: String) throws {
    let secretData = Data(secret.utf8)
    guard secretData.count >= 32, secretData.count <= 4 * 1024 else {
      throw Error.invalidSecret
    }
    self.key = SymmetricKey(data: secretData)
    let keyDigest = SHA256.hash(data: secretData)
    self.keyId = String(Base64URL.encodeNoPadding(digest: keyDigest).prefix(16))
  }

  func issue(
    accessTokenJWT: String,
    did: String,
    cnfJkt: String,
    tokenExpiresAt: Date,
    authoritativeValidUntil: Date,
    now: Date = Date()
  ) throws -> String {
    let validUntil = min(
      tokenExpiresAt,
      min(authoritativeValidUntil, now.addingTimeInterval(Self.maximumLifetime))
    )
    guard validUntil > now,
      Self.validBoundedDID(did),
      Self.validBoundedThumbprint(cnfJkt),
      accessTokenJWT.utf8.count <= 32 * 1024
    else {
      throw Error.invalid
    }

    let claims = Claims(
      version: 1,
      keyId: keyId,
      issuedAt: Int64(now.timeIntervalSince1970.rounded(.down)),
      validUntil: Int64(validUntil.timeIntervalSince1970.rounded(.down)),
      accessTokenHash: AccessTokenAth.expectedAth(accessTokenJWT: accessTokenJWT),
      did: did,
      cnfJkt: cnfJkt
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = Base64URL.encodeNoPadding(data: try encoder.encode(claims))
    let signature = HMAC<SHA256>.authenticationCode(
      for: Data(payload.utf8),
      using: key
    )
    return "\(payload).\(Base64URL.encodeNoPadding(data: Data(signature)))"
  }

  func verify(
    _ receipt: String,
    accessTokenJWT: String,
    expectedDID: String,
    expectedCnFJkt: String,
    tokenExpiresAt: Date,
    now: Date = Date()
  ) throws -> VerifiedClaims {
    guard receipt.utf8.count <= Self.maximumReceiptBytes,
      accessTokenJWT.utf8.count <= 32 * 1024,
      Self.validBoundedDID(expectedDID),
      Self.validBoundedThumbprint(expectedCnFJkt)
    else {
      throw Error.invalid
    }
    let segments = receipt.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 2,
      segments[0].utf8.count <= 3 * 1024,
      segments[1].utf8.count <= 128,
      let signature = try? Base64URL.decode(String(segments[1])),
      signature.count == SHA256.byteCount,
      HMAC<SHA256>.isValidAuthenticationCode(
        signature,
        authenticating: Data(segments[0].utf8),
        using: key
      ),
      let payload = try? Base64URL.decode(String(segments[0])),
      payload.count <= 2 * 1024,
      let claims = try? JSONDecoder().decode(Claims.self, from: payload)
    else {
      throw Error.invalid
    }

    let issuedAt = Date(timeIntervalSince1970: TimeInterval(claims.issuedAt))
    let validUntil = Date(timeIntervalSince1970: TimeInterval(claims.validUntil))
    guard claims.version == 1,
      claims.keyId == keyId,
      Self.validBoundedDID(claims.did),
      Self.validBoundedThumbprint(claims.cnfJkt),
      claims.accessTokenHash.utf8.count == 43,
      claims.did == expectedDID,
      claims.cnfJkt == expectedCnFJkt,
      claims.accessTokenHash == AccessTokenAth.expectedAth(accessTokenJWT: accessTokenJWT),
      issuedAt <= now.addingTimeInterval(5),
      validUntil > issuedAt,
      validUntil <= tokenExpiresAt,
      validUntil.timeIntervalSince(issuedAt) <= Self.maximumLifetime
    else {
      throw Error.invalid
    }
    guard validUntil > now else { throw Error.expired }
    return VerifiedClaims(
      did: claims.did,
      cnfJkt: claims.cnfJkt,
      issuedAt: issuedAt,
      validUntil: validUntil
    )
  }

  static func validatedReceipt(_ raw: String?) -> String? {
    guard let receipt = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
      !receipt.isEmpty,
      receipt.utf8.count <= maximumReceiptBytes,
      !receipt.contains(",")
    else { return nil }
    return receipt
  }

  private static func validBoundedDID(_ value: String) -> Bool {
    value.hasPrefix("did:") && !value.isEmpty && value.utf8.count <= 2 * 1024
  }

  private static func validBoundedThumbprint(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
  }
}
