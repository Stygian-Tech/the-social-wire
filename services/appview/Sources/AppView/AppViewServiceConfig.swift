import Foundation
import GatewayCore
import ThinAppViewCore

struct AppViewServiceConfig: Sendable {
  let core: GatewayConfig
  let thinAppView: ThinAppViewConfig
  let storeBackend: StoreBackend
  let wire: WireDiscoveryConfig
  let circle: CircleDiscoveryConfig

  enum StoreBackend: Sendable {
    case sqlite(path: String)
    case postgres(url: String)
  }

  static func fromEnvironment(
    _ env: [String: String] = AppEnvironmentLoader.mergeProcessWithDotenv()
  ) throws -> AppViewServiceConfig {
    let core = GatewayConfig.fromEnvironment(env)
    let thin = ThinAppViewConfig.fromEnvironment(env)
    let backend: StoreBackend
    switch core.appEnv {
    case .local:
      backend = .sqlite(path: env["SQLITE_DB_PATH"] ?? "./social-wire-appview.sqlite")
    case .dev, .prod:
      guard let dbURL = env["DATABASE_URL"], !dbURL.isEmpty else {
        fatalError("DATABASE_URL is required for APP_ENV=\(core.appEnv.rawValue)")
      }
      backend = .postgres(url: dbURL)
    }
    let wire = try WireDiscoveryConfig.fromEnvironment(env)
    let circle = try CircleDiscoveryConfig.fromEnvironment(env)
    if core.appEnv == .dev, (wire.mode.servesAPI || circle.mode.servesAPI), wire.corpusEdge == nil {
      throw WireDiscoveryConfigError.missingCorpusEdgeForDevelopment
    }
    if core.appEnv == .prod, wire.corpusEdge != nil {
      throw WireDiscoveryConfigError.remoteCorpusEdgeNotAllowedInProduction
    }
    return AppViewServiceConfig(
      core: core,
      thinAppView: thin,
      storeBackend: backend,
      wire: wire,
      circle: circle
    )
  }
}
