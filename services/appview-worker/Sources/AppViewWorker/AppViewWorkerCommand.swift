import AsyncHTTPClient
import ArgumentParser
import Foundation
import Logging
import OperationsCore
import PostgresNIO
import ThinAppViewCore

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AppViewWorkerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "The Social Wire AppView ingestion worker"
  )

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.appview-worker")
    logger.logLevel = .info
    let workerLogger = logger

    let environment = RuntimeEnvironment.mergeProcessWithDotenv()
    let operationsEnvironment = try OperationsConfiguration.requireEnvironment(environment)
    let thinConfig = ThinAppViewConfig.fromEnvironment(environment)
    let tapConfiguration = try TapConsumerConfiguration.fromEnvironment(environment)
    let operationsConfig = OperationsConfiguration.fromEnvironment(environment)
    guard thinConfig.enabled else {
      throw WorkerRuntimeError.thinAppViewDisabled
    }

    let proactiveExtraAuthorDids = (environment["THIN_APPVIEW_PROACTIVE_BACKFILL_AUTHOR_DIDS"] ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let backend = try DatabaseBackend.fromEnvironment(environment)
    let plcURL = environment["ATPROTO_PLC_URL"] ?? "https://plc.directory"
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    defer { Task { try? await httpClient.shutdown() } }

    switch backend {
    case .sqlite(let path):
      let store = try SQLiteThinAppViewStore(path: path, logger: workerLogger)
      let operationsStore = try SQLiteOperationsStore(
        path: path,
        environment: operationsEnvironment,
        backfillFingerprintSecret: operationsConfig.backfillFingerprintSecret,
        logger: workerLogger
      )
      try await ThinAppViewWorkerRuntime.run(
        store: store,
        config: thinConfig,
        logger: workerLogger,
        httpClient: httpClient,
        plcURL: plcURL,
        proactiveExtraAuthorDids: proactiveExtraAuthorDids,
        operationsStore: operationsStore,
        operationsConfig: operationsConfig,
        tapConfiguration: tapConfiguration
      )

    case .postgres(let urlString):
      let pgConfig = try makePostgresConfig(from: urlString, logger: workerLogger)
      let pgPool = PostgresClient(configuration: pgConfig, backgroundLogger: workerLogger)
      let store = PostgresThinAppViewStore(pool: pgPool, logger: workerLogger)
      let projectionCache = PostgresAppViewProjectionCacheStore(pool: pgPool, logger: workerLogger)
      let operationsStore = PostgresOperationsStore(
        pool: pgPool,
        environment: operationsEnvironment,
        backfillFingerprintSecret: operationsConfig.backfillFingerprintSecret,
        logger: workerLogger
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pgPool.run() }
        group.addTask {
          try await ThinAppViewWorkerRuntime.run(
            store: store,
            config: thinConfig,
            logger: workerLogger,
            httpClient: httpClient,
            plcURL: plcURL,
            proactiveExtraAuthorDids: proactiveExtraAuthorDids,
            projectionCache: projectionCache,
            operationsStore: operationsStore,
            operationsConfig: operationsConfig,
            tapConfiguration: tapConfiguration
          )
        }
        try await group.next()
        group.cancelAll()
      }
    }
  }
}

enum WorkerRuntimeError: Error, CustomStringConvertible {
  case thinAppViewDisabled

  var description: String {
    "ENABLE_THIN_APPVIEW must be true to run the worker."
  }
}
