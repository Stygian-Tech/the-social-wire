import Crypto
import Foundation
import Hummingbird

/// Validates RFC 9449 DPoP proofs for bound access tokens (ES‑256 with embedded **`jwk`** header keys).
enum DPoPProofVerifier {
  enum VerifyError: Swift.Error {
    case malformedJWT
    case unexpectedHeaderTyping
    case unsupportedJWTAlgorithm
    case invalidEllipticCurveJWK
    case invalidPayloadShape
    case staleOrFutureProofClock
    case methodMismatch(expected: String, got: String)
    case urlMismatch(expected: String, got: String)
    case athMismatch
    case jwkThumbprintMismatch(expected: String, got: String)
    case signatureVerificationFailed
  }

  private static let skewTolerance: TimeInterval = 120

  static func verify(proofJWT: String, request: Request, accessTokenJWT: String, accessTokenCnFJkt: String?) throws {
    guard let canonical = DPoPHtu.canonical(for: request) else {
      throw VerifyError.urlMismatch(expected: "<unresolved>", got: "<unresolved>")
    }

    try verify(
      proofJWT: proofJWT,
      uppercasedHTTPMethod: request.method.rawValue.uppercased(),
      expectedHtuURL: canonical,
      accessTokenJWT: accessTokenJWT,
      accessTokenCnFJkt: accessTokenCnFJkt
    )
  }

  static func verify(
    proofJWT: String,
    uppercasedHTTPMethod: String,
    expectedHtuURL: String,
    accessTokenJWT: String,
    accessTokenCnFJkt: String?
  ) throws {
    let parts = proofJWT.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw VerifyError.malformedJWT }

    let headerData = try Base64URL.decode(String(parts[0]))
    guard let headerObj = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
      throw VerifyError.invalidEllipticCurveJWK
    }

    if let typ = headerObj["typ"] as? String {
      guard typ.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "dpop+jwt" else {
        throw VerifyError.unexpectedHeaderTyping
      }
    }

    guard let alg = headerObj["alg"] as? String, alg.uppercased() == "ES256" else {
      throw VerifyError.unsupportedJWTAlgorithm
    }

    guard let jwkDict = headerObj["jwk"] as? [String: Any] else { throw VerifyError.invalidEllipticCurveJWK }

    let payloadData = try Base64URL.decode(String(parts[1]))
    guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
      throw VerifyError.invalidPayloadShape
    }

    let now = Date()
    guard let iatSeconds = numericTimestamp(payload["iat"]), iatSeconds > 0 else {
      throw VerifyError.invalidPayloadShape
    }

    let proofInstant = Date(timeIntervalSince1970: iatSeconds)
    guard abs(now.timeIntervalSince(proofInstant)) <= Self.skewTolerance else {
      throw VerifyError.staleOrFutureProofClock
    }

    if let expectedExp = numericTimestamp(payload["exp"]) {
      let expiration = Date(timeIntervalSince1970: expectedExp)
      guard expiration > now.addingTimeInterval(-Self.skewTolerance) else {
        throw VerifyError.staleOrFutureProofClock
      }
    }

    guard let jti = payload["jti"] as? String, !jti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw VerifyError.invalidPayloadShape
    }

    guard let proofMethod = payload["htm"] as? String else { throw VerifyError.invalidPayloadShape }
    guard proofMethod.uppercased() == uppercasedHTTPMethod else {
      throw VerifyError.methodMismatch(expected: uppercasedHTTPMethod, got: proofMethod.uppercased())
    }

    guard let proofURL = payload["htu"] as? String else { throw VerifyError.invalidPayloadShape }
    guard DPoPHtu.matches(proofURL: proofURL, expected: expectedHtuURL) else {
      throw VerifyError.urlMismatch(expected: expectedHtuURL, got: proofURL)
    }

    let thumbprintBase64URL = try jwkSha256Thumbprint(ecJWK: jwkDict)

    if let expectedJkt = accessTokenCnFJkt?.trimmingCharacters(in: .whitespacesAndNewlines), !expectedJkt.isEmpty {
      guard thumbprintBase64URL.caseInsensitiveCompare(expectedJkt) == .orderedSame else {
        throw VerifyError.jwkThumbprintMismatch(expected: expectedJkt, got: thumbprintBase64URL)
      }
    }

    let computedAth = AccessTokenAth.expectedAth(accessTokenJWT: accessTokenJWT)
    guard let athClaim = payload["ath"] as? String else {
      throw VerifyError.athMismatch
    }
    guard normalizedBase64URL(athClaim) == normalizedBase64URL(computedAth) else {
      throw VerifyError.athMismatch
    }

    let signingInputData = Data(String(parts[0] + "." + parts[1]).utf8)

    let publicKey = try p256PublicKey(fromEcJWK: jwkDict)
    let sigBytes = try Base64URL.decode(String(parts[2]))
    guard sigBytes.count == 64 else { throw VerifyError.signatureVerificationFailed }

    let rawSig = try P256.Signing.ECDSASignature(rawRepresentation: sigBytes)
    let digest = SHA256.hash(data: signingInputData)
    guard publicKey.isValidSignature(rawSig, for: digest) else {
      throw VerifyError.signatureVerificationFailed
    }
  }

  // MARK: - Internals

  private static func numericTimestamp(_ candidate: Any?) -> TimeInterval? {
    if let d = candidate as? Double { return d }
    if let i = candidate as? Int64 { return TimeInterval(i) }
    if let i = candidate as? Int { return TimeInterval(i) }
    if let ns = candidate as? NSNumber { return ns.doubleValue }
    return nil
  }

  private static func normalizedBase64URL(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// RFC 7638 JWK thumbprint: Base64URL-encode (**no padding**) SHA‑256(**UTF‑8 canonical JSON**) of the required EC members.
  private static func jwkSha256Thumbprint(ecJWK: [String: Any]) throws -> String {
    guard
      let kty = ecJWK["kty"] as? String,
      let crv = ecJWK["crv"] as? String,
      let x = ecJWK["x"] as? String,
      let y = ecJWK["y"] as? String,
      kty.uppercased() == "EC",
      ["P-256", "secp256r1"].contains(crv)
    else {
      throw VerifyError.invalidEllipticCurveJWK
    }

    struct Canon: Codable {
      let crv: String
      let kty: String
      let x: String
      let y: String
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let body = Canon(crv: crv, kty: kty, x: x, y: y)
    let utf8Blob = try encoder.encode(body)
    let digest = SHA256.hash(data: utf8Blob)
    return Base64URL.encodeNoPadding(digest: digest)
  }

  private static func p256PublicKey(fromEcJWK jwk: [String: Any]) throws -> P256.Signing.PublicKey {
    guard
      let crv = jwk["crv"] as? String,
      let x = jwk["x"] as? String,
      let y = jwk["y"] as? String,
      ["P-256", "secp256r1"].contains(crv)
    else {
      throw VerifyError.invalidEllipticCurveJWK
    }

    let xBin = try Base64URL.decode(x)
    let yBin = try Base64URL.decode(y)
    guard xBin.count == 32, yBin.count == 32 else { throw VerifyError.invalidEllipticCurveJWK }

    var uncompressed = Data([0x04])
    uncompressed.append(xBin)
    uncompressed.append(yBin)
    return try P256.Signing.PublicKey(x963Representation: uncompressed)
  }
}
