import Foundation
import HTTPTypes

/// Reads `X-Forwarded-Proto` and infers sane defaults when serving behind gateways.
public enum ForwardedHTTP {
  static func forwardedProto(from headers: HTTPFields) -> String? {
    guard let name = HTTPField.Name("X-Forwarded-Proto"),
          let raw = headers[name]
    else { return nil }
    return raw.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
  }

  static func inferredScheme(forAuthority authority: String, headers: HTTPFields) -> String {
    forwardedProto(from: headers) ?? inferredSchemeIgnoringForwarded(forAuthority: authority)
  }

  private static func inferredSchemeIgnoringForwarded(forAuthority authority: String) -> String {
    let hostOnly = authority.split(separator: ":").first.map(String.init) ?? authority
    let lower = hostOnly.lowercased()
    if lower == "localhost" || lower.hasPrefix("127.") { return "http" }
    return "https"
  }
}
