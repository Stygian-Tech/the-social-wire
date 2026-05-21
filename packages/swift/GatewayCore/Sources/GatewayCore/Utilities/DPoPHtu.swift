import Foundation
import HTTPTypes
import Hummingbird

/// Builds the **`htu`** string DPoP proofs should target for this ingress path.
///
/// Mirrors common reverse-proxy behaviour: honours `X-Forwarded-Proto` and the effective authority.
public enum DPoPHtu {
  static func canonical(for request: Request) -> String? {
    let trimmedHost = trimmedAuthority(for: request) ?? trimmedHostHeader(from: request.headers)
    guard let authority = trimmedHost, !authority.isEmpty else { return nil }

    let scheme =
      trimmedLowercasedScheme(request.head.scheme)
      ?? ForwardedHTTP.inferredScheme(forAuthority: authority, headers: request.headers)

    var pathFragment = request.uri.path
    if pathFragment.isEmpty { pathFragment = "/" }
    if !pathFragment.hasPrefix("/") { pathFragment = "/" + pathFragment }

    if let query = request.uri.query, !query.isEmpty {
      return "\(scheme)://\(authority)\(pathFragment)?\(query)"
    }

    return "\(scheme)://\(authority)\(pathFragment)"
  }

  /// Case-insensitive match with light trimming used by DPoP validators.
  static func matches(proofURL: String, expected: String) -> Bool {
    let left = normalize(proofURL)
    let right = normalize(expected)
    return left.caseInsensitiveCompare(right) == .orderedSame
  }

  private static func trimmedAuthority(for request: Request) -> String? {
    request.head.authority?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }

  private static func trimmedHostHeader(from headers: HTTPFields) -> String? {
    guard let hostName = HTTPField.Name("Host") else { return nil }
    return headers[hostName]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }

  private static func trimmedLowercasedScheme(_ raw: String?) -> String? {
    guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
    return s.lowercased()
  }

  private static func normalize(_ raw: String) -> String {
    guard let parsed = URL(string: raw)?.absoluteString else {
      return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let trimmedTail = parsed.trimmingCharacters(in: .whitespacesAndNewlines)
    if let hashIdx = trimmedTail.firstIndex(of: "#") {
      return String(trimmedTail[..<hashIdx])
    }
    return trimmedTail
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
