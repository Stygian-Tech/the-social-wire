import Foundation
import GatewayCore
import ThinAppViewCore

/// Configuration loaded from environment variables at startup.
struct AppConfig: Sendable {
  let atprotoPLCURL: String
  let appEnv: AppEnvironment
  let cacheBackend: CacheBackend
  /// SPA origin for **`redirect_uris`** on **`/oauth/client-metadata.json`** when the web app is on another host.
  let oauthPublicOrigin: String?
  /// Optional **`client_id`** origin override for **`/ios-client-metadata.json`** only — leave unset so **`client_id`**
  /// always matches **`Host`** (fixes `invalid_client_metadata` when `OAUTH_PUBLIC_ORIGIN` targets the marketing site).
  let oauthIosMetadataOrigin: String?
  /// When `true`, keeps publication discovery/content routes online for phased migrations (default **`false`**).
  let enableLegacyContentAPI: Bool
  /// Thin AppView read index configuration.
  let thinAppView: ThinAppViewConfig
  /// Binds JWT access tokens from **registered OAuth clients / audiences** for hosted gateway traffic.
  let oauthGateway: OAuthGatewayClientPolicy

  enum AppEnvironment: String, Sendable {
    case local
    case dev
    case prod
  }

  enum CacheBackend: Sendable {
    /// SQLite file on disk. Used automatically when `APP_ENV=local`.
    case sqlite(path: String)
    /// Postgres (Supabase). Used for `APP_ENV` dev/prod pairings.
    case postgres(url: String)
  }

  static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> AppConfig {
    let appEnv = AppEnvironment(rawValue: env["APP_ENV"] ?? "local") ?? .local
    let plcURL = env["ATPROTO_PLC_URL"] ?? "https://plc.directory"

    let backend: CacheBackend
    switch appEnv {
    case .local:
      let sqlitePath = env["SQLITE_DB_PATH"] ?? "./social-wire.sqlite"
      backend = .sqlite(path: sqlitePath)

    case .dev, .prod:
      guard let dbURL = env["SUPABASE_DATABASE_URL"], !dbURL.isEmpty else {
        fatalError("SUPABASE_DATABASE_URL is required for APP_ENV=\(appEnv.rawValue)")
      }
      backend = .postgres(url: dbURL)
    }

    let oauthRaw = env["OAUTH_PUBLIC_ORIGIN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let oauthPublicOrigin = (oauthRaw?.isEmpty == false) ? oauthRaw : nil
    let oauthIosOrigRaw =
      env["OAUTH_IOS_METADATA_ORIGIN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let oauthIosMetadataOrigin = (oauthIosOrigRaw?.isEmpty == false) ? oauthIosOrigRaw : nil
    let enableLegacyContentAPI = Self.truthyFlag(env["ENABLE_LEGACY_CONTENT_API"])

    let gateway = OAuthGatewayClientPolicy(
      allowedClientIds: OAuthGatewayPolicyParser.delimiterTokenSet(env["OAUTH_GATEWAY_ALLOWED_CLIENT_IDS"]),
      allowedAudiences: OAuthGatewayPolicyParser.delimiterTokenSet(env["OAUTH_GATEWAY_ALLOWED_AUDIENCES"]),
      requireKnownClient: OAuthGatewayPolicyParser.truthy(env["OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT"])
    )

    return AppConfig(
      atprotoPLCURL: plcURL,
      appEnv: appEnv,
      cacheBackend: backend,
      oauthPublicOrigin: oauthPublicOrigin,
      oauthIosMetadataOrigin: oauthIosMetadataOrigin,
      enableLegacyContentAPI: enableLegacyContentAPI,
      thinAppView: ThinAppViewConfig.fromEnvironment(env),
      oauthGateway: gateway
    )
  }

  private static func truthyFlag(_ value: String?) -> Bool {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !trimmed.isEmpty
    else {
      return false
    }
    return ["1", "true", "yes", "on"].contains(trimmed)
  }
}
