import ArgumentParser
import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import OperationsCore
import PostgresNIO
import ThinAppViewCore

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct OperationsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "The Social Wire operations control plane")

  @Option(name: .long) var port: Int?
  @Option(name: .long) var hostname: String?

  mutating func run() async throws {
    var logger = Logger(label: "com.thesocialwire.operations")
    logger.logLevel = .info
    let serviceLogger = logger
    let environment = AppEnvironmentLoader.mergeProcessWithDotenv()
    let config = OperationsServiceConfig.fromEnvironment(environment)
    let port = port ?? Int(environment["PORT"] ?? "8083") ?? 8083
    let host = hostname ?? environment["BIND_HOST"] ?? "0.0.0.0"
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    defer { Task { try? await httpClient.shutdown() } }

    switch config.database {
    case .sqlite(let path):
      let store = try SQLiteOperationsStore(
        path: path, environment: config.operations.environment,
        backfillFingerprintSecret: config.operations.backfillFingerprintSecret,
        logger: serviceLogger)
      try await Self.runServer(
        config: config, store: store, httpClient: httpClient, logger: serviceLogger, host: host, port: port
      )
    case .postgres(let url):
      let pgConfig = try makePostgresConfig(from: url, logger: serviceLogger)
      let pool = PostgresClient(configuration: pgConfig, backgroundLogger: serviceLogger)
      let store = PostgresOperationsStore(
        pool: pool, environment: config.operations.environment,
        backfillFingerprintSecret: config.operations.backfillFingerprintSecret,
        logger: serviceLogger)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pool.run() }
        group.addTask {
          try await Self.runServer(
            config: config, store: store, httpClient: httpClient, logger: serviceLogger, host: host, port: port
          )
        }
        try await group.next()
        group.cancelAll()
      }
    }
  }

  private static func runServer(
    config: OperationsServiceConfig,
    store: any OperationsStore,
    httpClient: HTTPClient,
    logger: Logger,
    host: String,
    port: Int
  ) async throws {
    let telemetry = OperationsTelemetryBuffer(store: store, logger: logger)
    let router = OperationsRouterBuilder.router(
      config: config,
      httpClient: httpClient,
      store: store,
      telemetry: config.operations.enabled ? telemetry : nil,
      logger: logger
    )
    let app = Application(
      router: router,
      configuration: .init(address: .hostname(host, port: port))
    )
    let webhook: OperationsWebhookDelivery?
    if let url = config.operations.webhookURL, let secret = config.operations.webhookSecret {
      webhook = OperationsWebhookDelivery(url: url, secret: secret, httpClient: httpClient, logger: logger)
    } else {
      webhook = nil
    }
    let evaluator = AlertEvaluator(store: store, config: config.operations, logger: logger, webhook: webhook)
    let capabilityMonitor = OperationsCapabilityMonitor(
      resolver: OperationsCapabilityResolver(store: store, config: config.operations),
      store: store, logger: logger)
    let heartbeat = OperationsHeartbeatJob(
      store: store, service: "operations", environment: config.operations.environment,
      instanceId: config.operations.instanceId,
      dependencyProbe: {
        try await store.ping()
        let bounds = try await store.changeEventCursorBounds()
        let snapshot = await telemetry.snapshot()
        let now = Date()
        let alertDeliveryState: String
        if !config.operations.alertDeliveryEnabled {
          alertDeliveryState = "disabled_by_configuration"
        } else if config.operations.webhookURL != nil && config.operations.webhookSecret != nil {
          alertDeliveryState = "ready"
        } else {
          alertDeliveryState = "misconfigured"
        }
        let exporterState: String
        if !config.operations.enabled {
          exporterState = "disabled_by_configuration"
        } else if snapshot.consecutiveFailures > 0 {
          exporterState = "degraded"
        } else if snapshot.lastSuccessfulExportAt == nil {
          exporterState = "idle_no_export_yet"
        } else {
          exporterState = "ready"
        }
        var dependencies = [
          "operations_store": "ready",
          "event_log": "ready",
          "event_log_earliest_cursor": String(bounds.earliestAvailable),
          "event_log_latest_cursor": String(bounds.latest),
          "alert_delivery": alertDeliveryState,
          "telemetry_exporter": exporterState,
          "telemetry_queue_depth": String(snapshot.queueDepth),
          "telemetry_in_flight": String(snapshot.inFlightCount),
          "telemetry_queue_capacity": String(snapshot.capacity),
          "telemetry_dropped_total": String(snapshot.droppedCount),
          "telemetry_consecutive_failures": String(snapshot.consecutiveFailures),
          "telemetry_last_successful_export_at": snapshot.lastSuccessfulExportAt?.ISO8601Format()
            ?? "none",
        ]
        if let lastSuccessfulExportAt = snapshot.lastSuccessfulExportAt {
          dependencies["telemetry_last_export_age_seconds"] = String(
            max(0, now.timeIntervalSince(lastSuccessfulExportAt)))
        }
        var requiredDependencies: Set<String> = ["operations_store", "event_log"]
        if config.operations.alertDeliveryEnabled { requiredDependencies.insert("alert_delivery") }
        let readiness: OperationsHealthState = snapshot.consecutiveFailures > 0
          || alertDeliveryState == "misconfigured" ? .degraded : .healthy
        let telemetryHealth = Self.telemetryHealth(
          enabled: config.operations.enabled, snapshot: snapshot)
        return OperationsServiceProbeResult(
          liveness: .healthy,
          readiness: readiness,
          freshness: telemetryHealth.freshness,
          completeness: telemetryHealth.completeness,
          dependencyState: dependencies,
          requiredDependencyKeys: requiredDependencies,
          observedAt: now,
          validUntil: now.addingTimeInterval(10))
      },
      logger: logger)
    let retention = OperationsRetentionJob(store: store, logger: logger)
    let evidenceChanges = OperationsEvidenceChangeMonitor(store: store, logger: logger)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await app.run() }
      group.addTask { await evaluator.runForever() }
      group.addTask { await capabilityMonitor.runForever() }
      if config.operations.enabled { group.addTask { await telemetry.runForever() } }
      group.addTask { await heartbeat.runForever() }
      group.addTask { await retention.runForever() }
      group.addTask { await evidenceChanges.runForever() }
      try await group.next()
      group.cancelAll()
    }
  }

  static func telemetryHealth(
    enabled: Bool,
    snapshot: OperationsTelemetryBufferSnapshot
  ) -> (freshness: OperationsHealthState, completeness: OperationsHealthState) {
    guard enabled else { return (.unknown, .unknown) }
    return (
      snapshot.consecutiveFailures > 0 ? .degraded : .healthy,
      snapshot.droppedCount > 0 ? .degraded : .healthy)
  }
}
