import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Builds browser CORS policy for the public gateway edge (SPA + OAuth DPoP preflights).
public enum GatewayCORSPolicy {
  public static func allowedOrigins(
    config: GatewayConfig,
    env: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    var origins = Array(OAuthGatewayPolicyParser.delimiterTokenSet(env["CORS_ALLOWED_ORIGINS"]))
    if origins.isEmpty, let oauth = config.oauthPublicOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
       !oauth.isEmpty
    {
      origins.append(oauth)
    }
    if config.appEnv == .local {
      origins.append(contentsOf: [
        "http://localhost:3000",
        "http://127.0.0.1:3000",
      ])
    }
    return Array(Set(origins)).sorted()
  }

  public static func middleware(
    config: GatewayConfig,
    env: [String: String] = ProcessInfo.processInfo.environment
  ) -> CORSMiddleware<GatewayRequestContext> {
    let origins = allowedOrigins(config: config, env: env)
    let allowOrigin = resolveAllowOrigin(origins: origins, appEnv: config.appEnv)
    let dpopHeader = HTTPField.Name("DPoP")!
    let upstreamDpopHeader = HTTPField.Name(ATProtoUpstreamDPoP.headerName)!
    let latrGatewayDpopHeader = HTTPField.Name(LatrGatewayUpstreamDPoP.headerName)!
    return CORSMiddleware(
      allowOrigin: allowOrigin,
      allowHeaders: [
        .accept, .authorization, .contentType, .origin, .ifNoneMatch,
        dpopHeader, upstreamDpopHeader, latrGatewayDpopHeader,
      ],
      allowMethods: [.get, .post, .put, .delete, .head, .options],
      allowCredentials: true,
      maxAge: .seconds(3600)
    )
  }

  private static func resolveAllowOrigin(
    origins: [String],
    appEnv: GatewayConfig.AppEnvironment
  ) -> CORSMiddleware<GatewayRequestContext>.AllowOriginExtended {
    switch origins.count {
    case 0:
      return appEnv == .local ? .originBased : .none
    case 1:
      return .custom(origins[0])
    case 2:
      return .oneOf(origins[0], origins[1])
    case 3:
      return .oneOf(origins[0], origins[1], origins[2])
    case 4:
      return .oneOf(origins[0], origins[1], origins[2], origins[3])
    default:
      return appEnv == .local ? .originBased : .custom(origins[0])
    }
  }
}
