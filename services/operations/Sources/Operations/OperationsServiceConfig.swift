import Foundation
import GatewayCore
import OperationsCore

struct OperationsServiceConfig: Sendable {
  let core: GatewayConfig
  let operations: OperationsConfiguration
  let gatewayOperationsInternalSecret: String?
  let database: Database

  enum Database: Sendable {
    case sqlite(path: String)
    case postgres(url: String)
  }

  static func fromEnvironment(_ environment: [String: String]) -> OperationsServiceConfig {
    guard (try? OperationsConfiguration.requireEnvironment(environment)) != nil else {
      fatalError("APP_ENV must be explicitly set to dev or prod for the operations service")
    }
    let core = GatewayConfig.fromEnvironment(environment)
    let operations = OperationsConfiguration.fromEnvironment(environment)
    let database: Database
    switch core.appEnv {
    case .local:
      fatalError("APP_ENV=local is not a valid persisted Operations environment; use APP_ENV=dev")
    case .dev, .prod:
      guard let url = environment["SUPABASE_DATABASE_URL"], !url.isEmpty else {
        fatalError("SUPABASE_DATABASE_URL is required for the operations service")
      }
      database = .postgres(url: url)
    }
    return OperationsServiceConfig(
      core: core,
      operations: operations,
      gatewayOperationsInternalSecret: core.gatewayOperationsInternalSecret,
      database: database
    )
  }
}
