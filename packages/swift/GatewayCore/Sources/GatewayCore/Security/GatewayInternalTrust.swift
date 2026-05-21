import Crypto
import Foundation

/// HMAC trust boundary between the public Gateway and private AppView service.
public enum GatewayInternalTrust {
  public static let didHeaderName = "X-SocialWire-Gateway-DID"
  public static let timestampHeaderName = "X-SocialWire-Gateway-Timestamp"
  public static let signatureHeaderName = "X-SocialWire-Gateway-Signature"

  public enum TrustError: Error, Equatable {
    case missingSecret
    case missingHeader(String)
    case invalidTimestamp
    case staleTimestamp
    case invalidSignature
    case invalidDid
  }

  private static let skewTolerance: TimeInterval = 120

  /// Normalizes `path` and optional raw query for stable HMAC input across proxy hops.
  ///
  /// Decodes query pairs, sorts by name/value, and re-encodes so Gateway signing and AppView
  /// verification match even when AsyncHTTPClient/Hummingbird percent-encode differently.
  public static func canonicalPathWithQuery(path: String, query: String?) -> String {
    var normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedPath.isEmpty { normalizedPath = "/" }
    if !normalizedPath.hasPrefix("/") { normalizedPath = "/" + normalizedPath }

    guard let query, !query.isEmpty else { return normalizedPath }

    var items: [URLQueryItem] = []
    for component in query.split(separator: "&", omittingEmptySubsequences: false) {
      if let equalsIndex = component.firstIndex(of: "=") {
        let nameRaw = String(component[..<equalsIndex])
        let valueRaw = String(component[component.index(after: equalsIndex)...])
        let name = nameRaw.removingPercentEncoding ?? nameRaw
        let value = valueRaw.removingPercentEncoding ?? valueRaw
        items.append(URLQueryItem(name: name, value: value))
      } else {
        let nameRaw = String(component)
        let name = nameRaw.removingPercentEncoding ?? nameRaw
        items.append(URLQueryItem(name: name, value: nil))
      }
    }

    items.sort { lhs, rhs in
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return (lhs.value ?? "") < (rhs.value ?? "")
    }

    var components = URLComponents()
    components.queryItems = items
    guard let encodedQuery = components.percentEncodedQuery else {
      return "\(normalizedPath)?\(query)"
    }
    return "\(normalizedPath)?\(encodedQuery)"
  }

  /// Builds the signed header triple for an AppView-bound request.
  public static func signedHeaders(
    secret: String,
    did: String,
    method: String,
    pathWithQuery: String,
    timestamp: Date = Date()
  ) throws -> [(name: String, value: String)] {
    let normalizedDid = try normalizedDid(did)
    let unixSeconds = Int64(timestamp.timeIntervalSince1970)
    let timestampValue = String(unixSeconds)
    let signature = try sign(
      secret: secret,
      did: normalizedDid,
      method: method,
      pathWithQuery: pathWithQuery,
      timestamp: timestampValue
    )
    return [
      (name: didHeaderName, value: normalizedDid),
      (name: timestampHeaderName, value: timestampValue),
      (name: signatureHeaderName, value: signature),
    ]
  }

  /// Validates the internal trust headers on an inbound AppView request.
  public static func verify(
    secret: String,
    did: String,
    method: String,
    pathWithQuery: String,
    timestamp: String,
    signature: String,
    now: Date = Date()
  ) throws {
    guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TrustError.missingSecret
    }

    let normalizedDid = try normalizedDid(did)
    guard let unixSeconds = Int64(timestamp.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw TrustError.invalidTimestamp
    }

    let proofInstant = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    guard abs(now.timeIntervalSince(proofInstant)) <= skewTolerance else {
      throw TrustError.staleTimestamp
    }

    let expected = try sign(
      secret: secret,
      did: normalizedDid,
      method: method,
      pathWithQuery: pathWithQuery,
      timestamp: String(unixSeconds)
    )
    let provided = signature.trimmingCharacters(in: .whitespacesAndNewlines)
    guard constantTimeEquals(expected, provided) else {
      throw TrustError.invalidSignature
    }
  }

  static func canonicalRequest(
    did: String,
    method: String,
    pathWithQuery: String,
    timestamp: String
  ) -> String {
    [
      timestamp,
      method.uppercased(),
      pathWithQuery,
      did,
    ].joined(separator: "\n")
  }

  private static func sign(
    secret: String,
    did: String,
    method: String,
    pathWithQuery: String,
    timestamp: String
  ) throws -> String {
    let canonical = canonicalRequest(
      did: did,
      method: method,
      pathWithQuery: pathWithQuery,
      timestamp: timestamp
    )
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
    return Base64URL.encodeNoPadding(data: Data(mac))
  }

  private static func normalizedDid(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("did:") else {
      throw TrustError.invalidDid
    }
    return trimmed
  }

  private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }
}
