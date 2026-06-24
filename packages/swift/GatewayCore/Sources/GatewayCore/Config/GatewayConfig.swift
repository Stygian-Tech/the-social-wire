import Foundation
import ThinAppViewCore

/// Shared gateway / appview configuration loaded from environment at startup.
public struct GatewayConfig: Sendable {
  public let atprotoPLCURL: String
  public let appEnv: AppEnvironment
  /// SPA origin for **`redirect_uris`** on **`/oauth-client-metadata.json`** when the web app is on another host.
  public let oauthPublicOrigin: String?
  /// Optional **`client_id`** origin override for **`/ios-client-metadata.json`** only.
  public let oauthIosMetadataOrigin: String?
  /// Binds JWT access tokens from registered OAuth clients for hosted gateway traffic.
  public let oauthGateway: OAuthGatewayClientPolicy
  /// Optional operator-provided JWKS JSON for OAuth access-token verification when issuer metadata omits signing keys.
  public let oauthAccessTokenSupplementalJwksJSON: String?
  /// Shared HMAC secret for Gateway → AppView internal trust (`GATEWAY_APPVIEW_INTERNAL_SECRET`).
  public let gatewayAppViewInternalSecret: String?

  public enum AppEnvironment: String, Sendable {
    case local
    case dev
    case prod
  }

  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> GatewayConfig {
    let appEnv = AppEnvironment(rawValue: env["APP_ENV"] ?? "local") ?? .local
    let plcURL = env["ATPROTO_PLC_URL"] ?? "https://plc.directory"
    let oauthRaw = env["OAUTH_PUBLIC_ORIGIN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let oauthPublicOrigin = (oauthRaw?.isEmpty == false) ? oauthRaw : nil
    let oauthIosOrigRaw =
      env["OAUTH_IOS_METADATA_ORIGIN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let oauthIosMetadataOrigin = (oauthIosOrigRaw?.isEmpty == false) ? oauthIosOrigRaw : nil
    let gateway = OAuthGatewayClientPolicy(
      allowedClientIds: OAuthGatewayPolicyParser.delimiterTokenSet(env["OAUTH_GATEWAY_ALLOWED_CLIENT_IDS"]),
      allowedAudiences: OAuthGatewayPolicyParser.delimiterTokenSet(env["OAUTH_GATEWAY_ALLOWED_AUDIENCES"]),
      requireKnownClient: OAuthGatewayPolicyParser.truthy(env["OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT"])
    )
    let supplementalJwksRaw =
      env["OAUTH_ACCESS_TOKEN_SUPPLEMENTAL_JWKS_JSON"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let oauthAccessTokenSupplementalJwksJSON =
      (supplementalJwksRaw?.isEmpty == false) ? supplementalJwksRaw : nil
    let internalSecretRaw =
      env["GATEWAY_APPVIEW_INTERNAL_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let gatewayAppViewInternalSecret =
      (internalSecretRaw?.isEmpty == false) ? internalSecretRaw : nil
    return GatewayConfig(
      atprotoPLCURL: plcURL,
      appEnv: appEnv,
      oauthPublicOrigin: oauthPublicOrigin,
      oauthIosMetadataOrigin: oauthIosMetadataOrigin,
      oauthGateway: gateway,
      oauthAccessTokenSupplementalJwksJSON: oauthAccessTokenSupplementalJwksJSON,
      gatewayAppViewInternalSecret: gatewayAppViewInternalSecret
    )
  }
}
