import Foundation

/// Identity-only ATProto OAuth metadata for the protected Operations console.
public enum OperationsOAuthClientMetadata {
  enum BuildError: Error {
    case invalidPublicOrigin
  }

  static func buildJSON(publicOrigin: String, redirectOrigin: String) throws -> Data {
    let metadataBase = try normalizedOrigin(publicOrigin)
    let redirectBase = try normalizedOrigin(redirectOrigin)

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

    let document = MetadataBody(
      client_id: "\(metadataBase)/operations-oauth-client-metadata.json",
      application_type: "web",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      redirect_uris: ["\(redirectBase)/callback"],
      scope: "atproto",
      token_endpoint_auth_method: "none",
      dpop_bound_access_tokens: true,
      client_name: "The Social Wire Operations",
      client_uri: metadataBase
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(document)
  }

  private static func normalizedOrigin(_ raw: String) throws -> String {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
          url.path.isEmpty || url.path == "/"
    else {
      throw BuildError.invalidPublicOrigin
    }
    return trimmed
  }
}
