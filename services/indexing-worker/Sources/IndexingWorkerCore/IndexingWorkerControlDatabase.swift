import Logging
import OperationsCore
import PostgresNIO
import ThinAppViewCore

struct IndexingWorkerControlDatabase: Sendable {
  let pool: PostgresClient
  let diagnosticPool: PostgresClient
  let store: PostgresOperationsStore
  let diagnostics: PostgresRoleLeaseDiagnosticSampler

  static func make(
    role: IndexingWorkerRole, databaseURL: String, environment: [String: String],
    appEnvironment: String, logger: Logger
  ) throws -> Self? {
    guard role == .coordinator else { return nil }
    var configuration = try makePostgresConfig(
      from: databaseURL, logger: logger, component: "authority")
    configuration.options.maximumConnections = 2
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    var diagnosticConfiguration = try makePostgresConfig(
      from: databaseURL, logger: logger, component: "lease-diagnostics")
    diagnosticConfiguration.options.minimumConnections = 0
    diagnosticConfiguration.options.maximumConnections = 1
    diagnosticConfiguration.options.connectionIdleTimeout = .seconds(10)
    let diagnosticPool = PostgresClient(
      configuration: diagnosticConfiguration,
      backgroundLogger: Logger(label: "lease-diagnostic-pool", factory: { _ in SwiftLogNoOpLogHandler() }))
    let operationsConfiguration = OperationsConfiguration.fromEnvironment(environment)
    return Self(
      pool: pool, diagnosticPool: diagnosticPool,
      store: PostgresOperationsStore(
        pool: pool, environment: appEnvironment,
        backfillFingerprintSecret: operationsConfiguration.backfillFingerprintSecret, logger: logger),
      diagnostics: PostgresRoleLeaseDiagnosticSampler(
        pool: diagnosticPool, environment: appEnvironment, logger: logger))
  }
}
