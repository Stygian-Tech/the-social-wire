import Foundation

/// ATProto native OAuth client metadata (`application_type: native`), aligned with
/// `apps/web/public/ios-client-metadata.json`.
enum IosOAuthClientMetadata {
  enum BuildError: Error {
    case invalidPublicOrigin
  }

  /// Space-separated scopes — kept in sync with web `client-metadata.json` via `ATProtoOAuthScopes`.
  static var scope: String { ATProtoOAuthScopes.scope }

  /// Reversed domain labels for ATProto native redirect scheme hosts.
  static func nativeURLScheme(host: String) -> String {
    host.split(separator: ".").reversed().joined(separator: ".")
  }

  static func nativeRedirectURI(host: String) -> String {
    "\(nativeURLScheme(host: host)):/oauth/callback"
  }

  /// When `nativeRedirectHost` is set, **`redirect_uris`** use that host while **`client_id`** still reflects **`publicOrigin`** (Swift API deployed on **`api.*`** keeps **`app.thesocialwire`** callbacks).
  ///
  /// - Parameter nativeRedirectHost: Optional scheme-less host (`thesocialwire.app`). When **`nil`/empty**, `redirect_uris` follow **`URL(publicOrigin)?.host`** (tunnel / parity with older callers).
  static func buildJSON(publicOrigin: String, nativeRedirectHost: String?) throws -> Data {
    var trimmed = publicOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let originHost = URL(string: trimmed)?.host, !originHost.isEmpty else {
      throw BuildError.invalidPublicOrigin
    }
    let redirectCandidate = nativeRedirectHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let redirectHost = redirectCandidate.isEmpty ? originHost : redirectCandidate
    let base = trimmed
    let client_id = "\(base)/ios-client-metadata.json"
    let redirect = nativeRedirectURI(host: redirectHost)
    let doc = MetadataBody(
      client_id: client_id,
      application_type: "native",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      redirect_uris: [redirect],
      scope: Self.scope,
      token_endpoint_auth_method: "none",
      dpop_bound_access_tokens: true,
      client_name: "The Social Wire",
      client_uri: base
    )
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    return try enc.encode(doc)
  }

  /// - Parameter publicOrigin: Scheme + host (+ optional non-default port), no trailing slash, e.g. `https://example.com` or `http://127.0.0.1:8090`.
  static func buildJSON(publicOrigin: String) throws -> Data {
    try buildJSON(publicOrigin: publicOrigin, nativeRedirectHost: nil)
  }

  private struct MetadataBody: Encodable {
    let client_id: String
    let application_type: String
    let grant_types: [String]
    let response_types: [String]
    let redirect_uris: [String]
    let scope: String
    let token_endpoint_auth_method: String
    let dpop_bound_access_tokens: Bool
    let client_name: String
    let client_uri: String
  }
}
