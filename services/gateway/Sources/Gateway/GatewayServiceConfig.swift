import Foundation
import GatewayCore

/// Gateway-specific configuration (PDS write-through, sync cache, optional AppView read proxy).
struct GatewayServiceConfig: Sendable {
  let core: GatewayConfig
  let cacheBackend: CacheBackend
  /// When set, publication/AppView XRPC and their compatibility aliases are proxied to this AppView base URL.
  let appViewBaseURL: String?
  /// Dedicated control-plane origin for `/v1/operations/*`.
  let operationsBaseURL: String?
  /// Charybdis health origin used by the public readiness aggregation endpoint.
  let charybdisBaseURL: String?
  /// When set, `link.latr.bookmarks.*` XRPC is proxied to L@tr using iOS server credentials.
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
      guard let dbURL = env["DATABASE_URL"], !dbURL.isEmpty else {
        fatalError("DATABASE_URL is required for APP_ENV=\(core.appEnv.rawValue)")
      }
      backend = .postgres(url: dbURL)
    }
    let appViewRaw = env["APPVIEW_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let appViewBaseURL = (appViewRaw?.isEmpty == false) ? appViewRaw : nil
    let operationsRaw = env["OPERATIONS_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let operationsBaseURL = (operationsRaw?.isEmpty == false) ? operationsRaw : nil
    let charybdisRaw = env["CHARYBDIS_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let charybdisBaseURL = (charybdisRaw?.isEmpty == false) ? charybdisRaw : nil
    let latrIosProxy = LatrIosProxyCredentials.Config.fromEnvironment(env)
    return GatewayServiceConfig(
      core: core,
      cacheBackend: backend,
      appViewBaseURL: appViewBaseURL,
      operationsBaseURL: operationsBaseURL,
      charybdisBaseURL: charybdisBaseURL,
      latrIosProxy: latrIosProxy
    )
  }
}
