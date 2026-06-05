import Foundation
import GatewayCore

/// Gateway-specific configuration (PDS write-through, sync cache, optional AppView read proxy).
struct GatewayServiceConfig: Sendable {
  let core: GatewayConfig
  let cacheBackend: CacheBackend
  /// When set, `GET /v1/publications/sidebar` is proxied to this AppView service base URL.
  let appViewBaseURL: String?
  /// When set, `/v1/latr/*` is proxied to the external L@tr Gateway using iOS-proxy server credentials.
  let latrIosProxy: LatrIosProxyCredentials.Config?

  enum CacheBackend: Sendable {
    case sqlite(path: String)
    case postgres(url: String)
  }

  static func fromEnvironment(
    _ env: [String: String] = AppEnvironmentLoader.mergeProcessWithDotenv()
  ) -> GatewayServiceConfig {
    let core = GatewayConfig.fromEnvironment(env)
    let backend: CacheBackend
    switch core.appEnv {
    case .local:
      backend = .sqlite(path: env["SQLITE_DB_PATH"] ?? "./social-wire.sqlite")
    case .dev, .prod:
      guard let dbURL = env["SUPABASE_DATABASE_URL"], !dbURL.isEmpty else {
        fatalError("SUPABASE_DATABASE_URL is required for APP_ENV=\(core.appEnv.rawValue)")
      }
      backend = .postgres(url: dbURL)
    }
    let appViewRaw = env["APPVIEW_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let appViewBaseURL = (appViewRaw?.isEmpty == false) ? appViewRaw : nil
    let latrIosProxy = LatrIosProxyCredentials.Config.fromEnvironment(env)
    return GatewayServiceConfig(
      core: core,
      cacheBackend: backend,
      appViewBaseURL: appViewBaseURL,
      latrIosProxy: latrIosProxy
    )
  }
}
