import Crypto
import Foundation

/// Dedicated AppView-to-corpus-edge authentication. This deliberately does not reuse
/// Gateway-to-AppView trust and signs the complete request target, including the query.
public enum WireCorpusServiceTrust {
  public static let serviceHeaderName = "X-Wire-Corpus-Service"
  public static let timestampHeaderName = "X-Wire-Corpus-Timestamp"
  public static let nonceHeaderName = "X-Wire-Corpus-Nonce"
  public static let signatureHeaderName = "X-Wire-Corpus-Signature"
  public static let maximumClockSkew: TimeInterval = 60

  public static func signedHeaders(
    secret: String,
    serviceID: String,
    method: String,
    target: String,
    timestamp: Date = Date(),
    nonce: String = UUID().uuidString.lowercased()
  ) throws -> WireCorpusServiceHeaders {
    try validate(secret: secret, serviceID: serviceID, target: target)
    try validateNonce(nonce)
    let seconds = Int64(timestamp.timeIntervalSince1970.rounded(.down))
    let timestampValue = String(seconds)
    let signature = signature(
      secret: secret,
      serviceID: serviceID,
      method: method,
      target: target,
      timestamp: timestampValue,
      nonce: nonce
    )
    return WireCorpusServiceHeaders(
      serviceID: serviceID,
      timestamp: timestampValue,
      nonce: nonce,
      signature: signature
    )
  }

  public static func verify(
    secret: String,
    expectedServiceID: String,
    presentedServiceID: String,
    method: String,
    target: String,
    timestamp: String,
    nonce: String,
    signature presentedSignature: String,
    now: Date = Date()
  ) throws {
    try validate(secret: secret, serviceID: expectedServiceID, target: target)
    guard presentedServiceID == expectedServiceID else {
      throw WireCorpusServiceTrustError.invalidServiceID
    }
    guard let seconds = Int64(timestamp) else {
      throw WireCorpusServiceTrustError.invalidTimestamp
    }
    let signedAt = Date(timeIntervalSince1970: TimeInterval(seconds))
    guard abs(now.timeIntervalSince(signedAt)) <= maximumClockSkew else {
      throw WireCorpusServiceTrustError.expiredTimestamp
    }
    try validateNonce(nonce)
    guard let decodedSignature = decodeBase64URL(presentedSignature) else {
      throw WireCorpusServiceTrustError.invalidSignature
    }
    let key = SymmetricKey(data: Data(secret.utf8))
    let message = Data(
      canonicalMessage(
        serviceID: presentedServiceID,
        method: method,
        target: target,
        timestamp: timestamp,
        nonce: nonce
      ).utf8
    )
    guard HMAC<SHA256>.isValidAuthenticationCode(decodedSignature, authenticating: message, using: key)
    else {
      throw WireCorpusServiceTrustError.invalidSignature
    }
  }

  public static func validateServiceID(_ serviceID: String) throws {
    guard !serviceID.isEmpty, serviceID.utf8.count <= 64,
      serviceID.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || byte == 45 || byte == 46 || byte == 95
      })
    else {
      throw WireCorpusServiceTrustError.invalidServiceID
    }
  }

  private static func validate(secret: String, serviceID: String, target: String) throws {
    guard secret.utf8.count >= 32 else { throw WireCorpusServiceTrustError.invalidSecret }
    try validateServiceID(serviceID)
    guard target.hasPrefix("/"), target.utf8.count <= 2_048,
      !target.contains("#"), !target.contains("\n"), !target.contains("\r")
    else {
      throw WireCorpusServiceTrustError.invalidTarget
    }
  }

  private static func signature(
    secret: String,
    serviceID: String,
    method: String,
    target: String,
    timestamp: String,
    nonce: String
  ) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let message = Data(
      canonicalMessage(
        serviceID: serviceID,
        method: method,
        target: target,
        timestamp: timestamp,
        nonce: nonce
      ).utf8
    )
    let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
    return Data(code).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func canonicalMessage(
    serviceID: String,
    method: String,
    target: String,
    timestamp: String,
    nonce: String
  ) -> String {
    "wire-corpus-v1\n\(serviceID)\n\(timestamp)\n\(nonce)\n\(method.uppercased())\n\(target)"
  }

  private static func validateNonce(_ nonce: String) throws {
    guard nonce.utf8.count == 36,
      UUID(uuidString: nonce) != nil,
      nonce.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) || byte == 45
      })
    else {
      throw WireCorpusServiceTrustError.invalidNonce
    }
  }

  private static func decodeBase64URL(_ value: String) -> Data? {
    guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
  }
}
