import Foundation
import GatewayCore
import ThinAppViewCore

struct AppViewServiceConfig: Sendable {
  let core: GatewayConfig
  let thinAppView: ThinAppViewConfig
  let storeBackend: StoreBackend

  enum StoreBackend: Sendable {
    case sqlite(path: String)
    case postgres(url: String)
  }

  static func fromEnvironment(
    _ env: [String: String] = AppEnvironmentLoader.mergeProcessWithDotenv()
  ) -> AppViewServiceConfig {
    let core = GatewayConfig.fromEnvironment(env)
    let thin = ThinAppViewConfig.fromEnvironment(env)
    let backend: StoreBackend
    switch core.appEnv {
    case .local:
      backend = .sqlite(path: env["SQLITE_DB_PATH"] ?? "./social-wire-appview.sqlite")
    case .dev, .prod:
      guard let dbURL = env["SUPABASE_DATABASE_URL"], !dbURL.isEmpty else {
        fatalError("SUPABASE_DATABASE_URL is required for APP_ENV=\(core.appEnv.rawValue)")
      }
      backend = .postgres(url: dbURL)
    }
    return AppViewServiceConfig(core: core, thinAppView: thin, storeBackend: backend)
  }
}
