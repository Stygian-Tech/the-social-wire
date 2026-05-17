import Foundation

/// ATProto **`application_type: web`** client metadata aligned with [`apps/web/public/client-metadata.json`].
enum WebOAuthClientMetadata {
  enum BuildError: Error {
    case invalidPublicOrigin
  }

  /// Builds JSON with `redirect_uris: ["{origin}/callback"]` — same semantics as deployed Next.js static asset.
  static func buildJSON(publicOrigin: String) throws -> Data {
    var trimmed = publicOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let host = URL(string: trimmed)?.host, !host.isEmpty else {
      throw BuildError.invalidPublicOrigin
    }

    let base = trimmed
    let client_id = "\(base)/oauth/client-metadata.json"
    let redirect = "\(base)/callback"

    struct MetadataBody: Encodable {
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

    let doc = MetadataBody(
      client_id: client_id,
      application_type: "web",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      redirect_uris: [redirect],
      scope: ATProtoOAuthScopes.scope,
      token_endpoint_auth_method: "none",
      dpop_bound_access_tokens: true,
      client_name: "The Social Wire",
      client_uri: base
    )
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    return try enc.encode(doc)
  }
}
