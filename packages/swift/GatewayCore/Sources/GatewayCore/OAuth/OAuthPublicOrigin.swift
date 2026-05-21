import Foundation
import HTTPTypes
import Hummingbird

/// Resolves the public `https://`/`http://` origin used in `client_id` and `client_uri`
/// for dynamically served OAuth client metadata.
///
/// **ATProto invariant:** fetched metadata’s `client_id` must match the retrieval URL — callers passing a
/// `configuredOrigin` unrelated to **`Host`** (e.g. web marketing domain) must not reuse that origin for **`/ios-client-metadata.json`**
/// when responses are reached via another host (Swift API subdomain).
public enum OAuthPublicOrigin {
  /// If `configuredOrigin` is non-empty, it wins; otherwise `X-Forwarded-Proto` + `:authority`
  /// (HTTP/1 **`Host`**), or inferred scheme for localhost.
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
