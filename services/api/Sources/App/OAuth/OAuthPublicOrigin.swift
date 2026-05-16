import Foundation
import HTTPTypes
import Hummingbird

/// Resolves the public `https://`/`http://` origin used in `client_id` and `client_uri`
/// for dynamically served OAuth client metadata.
enum OAuthPublicOrigin {
  /// Preferred: `OAUTH_PUBLIC_ORIGIN` when the service is not directly exposed (no accurate `Host`).
  /// Otherwise: `X-Forwarded-Proto` + `:authority` (HTTP/1 `Host`), or inferred scheme for localhost.
  static func resolve(request: Request, configuredOrigin: String?) -> String? {
    if let fixed = configuredOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !fixed.isEmpty {
      return stripTrailingSlash(fixed)
    }
    guard let authority = request.head.authority, !authority.isEmpty else { return nil }
    let proto = forwardedProto(request) ?? inferredProto(forAuthority: authority)
    return "\(proto)://\(authority)"
  }

  private static func forwardedProto(_ request: Request) -> String? {
    ForwardedHTTP.forwardedProto(from: request.headers)
  }

  private static func inferredProto(forAuthority authority: String) -> String {
    ForwardedHTTP.inferredScheme(forAuthority: authority, headers: [:])
  }

  private static func stripTrailingSlash(_ s: String) -> String {
    if s.hasSuffix("/") { return String(s.dropLast()) }
    return s
  }
}
