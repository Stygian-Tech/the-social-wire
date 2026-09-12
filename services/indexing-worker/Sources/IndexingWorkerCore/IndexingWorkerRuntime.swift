import AppViewWorkerCore
import AsyncHTTPClient
import Foundation
import Logging
import OperationsCore
import PostgresNIO
import ThinAppViewCore
import WireWorkerCore

public enum IndexingWorkerRuntime {
  public static func run(
    environment: [String: String],
    config: IndexingWorkerConfig,
    logger: Logger,
    terminateUnresponsiveProcess: @escaping @Sendable () -> Void
  ) async throws {
    guard let databaseURL = environment["DATABASE_URL"], !databaseURL.isEmpty else {
      throw IndexingWorkerRuntimeError.missingDatabaseURL
    }
    let appEnvironment = try OperationsConfiguration.requireEnvironment(environment)
    let operationsConfiguration = OperationsConfiguration.fromEnvironment(environment)
    var postgresConfiguration = try makePostgresConfig(from: databaseURL, logger: logger)
    if config.role == .coordinator {
      // Dedicated control capacity: hosted lane workloads have separate pools.
      postgresConfiguration.options.maximumConnections = 2
    }
    let pool = PostgresClient(configuration: postgresConfiguration, backgroundLogger: logger)
    // Failure diagnostics never borrow the two authority-control connections. This
    // lazy connection is opened only after a failure and retired after idle time.
    var diagnosticConfiguration = postgresConfiguration
    diagnosticConfiguration.options.minimumConnections = 0
    diagnosticConfiguration.options.maximumConnections = 1
    diagnosticConfiguration.options.connectionIdleTimeout = .seconds(10)
    diagnosticConfiguration.options.additionalStartupParameters.removeAll { $0.0 == "application_name" }
    diagnosticConfiguration.options.additionalStartupParameters.append(("application_name", "coordinator-lease-diagnostics"))
    let diagnosticPool = PostgresClient(configuration: diagnosticConfiguration,
      backgroundLogger: Logger(label: "lease-diagnostic-pool", factory: { _ in SwiftLogNoOpLogHandler() }))
    let leaseDiagnostics = PostgresRoleLeaseDiagnosticSampler(
      pool: diagnosticPool, environment: appEnvironment, logger: logger)
    let operationsStore = PostgresOperationsStore(
      pool: pool,
      environment: appEnvironment,
      backfillFingerprintSecret: operationsConfiguration.backfillFingerprintSecret,
      logger: logger
    )
    let healthClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let laneState = IndexingWorkerLaneState()

    logger.info(
      "Starting consolidated indexing worker",
      metadata: [
        "role": .string(config.role.rawValue),
        "owner_id": .string(config.ownerID),
      ]
    )

    var runtimeError: Error?
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await pool.run() }
        if config.role == .coordinator {
          group.addTask { await diagnosticPool.run() }
          group.addTask {
            try await IndexingWorkerShutdownWatchdog.run(
              state: laneState, logger: logger, terminate: terminateUnresponsiveProcess)
          }
        }
        group.addTask {
          try await IndexingWorkerHealthServer.run(
            role: config.role,
            startupProbe: {
              if config.role == .coordinator {
                guard await laneState.hasRecentControlEvidence(maximumAge: config.controlEvidenceMaximumAge) else {
                  throw IndexingWorkerRuntimeError.controlEvidenceUnavailable
                }
              } else {
                try await operationsStore.ping()
              }
              try await probeLanes(
                role: config.role,
                path: "/startupz",
                config: config,
                state: laneState,
                client: healthClient
              )
            },
            readinessProbe: {
              if config.role == .coordinator {
                guard await laneState.hasRecentControlEvidence(maximumAge: config.controlEvidenceMaximumAge) else {
                  throw IndexingWorkerRuntimeError.controlEvidenceUnavailable
                }
              } else {
                try await operationsStore.ping()
              }
              try await probeLanes(
                role: config.role,
                path: "/readyz",
                config: config,
                state: laneState,
                client: healthClient
              )
            },
            host: config.host,
            port: config.port,
            logger: logger
          )
        }

        switch config.role {
        case .projection:
          group.addTask {
            try await IndexingWorkerComponentSupervisor.run(
              lane: .appView,
              state: laneState,
              logger: logger
            ) {
              try await AppViewWorkerHost.run(
                environment: environment,
                role: .projection,
                serviceName: "projection-pool-appview",
                healthListener: .enabled(
                  hostname: "127.0.0.1", port: config.appViewHealthPort
                ),
                logger: logger
              )
            }
          }
          group.addTask {
            try await IndexingWorkerComponentSupervisor.run(
              lane: .wire,
              state: laneState,
              logger: logger
            ) {
              try await WireWorkerHost.run(
                environment: environment,
                role: .drain,
                healthListener: .enabled(
                  hostname: "127.0.0.1", port: config.wireHealthPort
                ),
                logger: logger
              )
            }
          }

        case .coordinator:
          group.addTask {
            await runCoordinatorLane(
              roleName: "indexing.appview-coordinator",
              lane: .appView,
              state: laneState,
              store: operationsStore,
              diagnostics: leaseDiagnostics,
              config: config,
              logger: logger
            ) { ownership in
              try await AppViewWorkerHost.run(
                environment: environment,
                role: .coordinator,
                serviceName: "coordinator-appview",
                healthListener: .enabled(
                  hostname: "127.0.0.1", port: config.appViewHealthPort
                ),
                roleLeaseAuthority: ownership.authority,
                logger: logger
              )
            }
          }
          group.addTask {
            await runCoordinatorLane(
              roleName: "indexing.wire-materializer",
              lane: .wire,
              state: laneState,
              store: operationsStore,
              diagnostics: leaseDiagnostics,
              config: config,
              logger: logger
            ) { ownership in
              try await WireWorkerHost.run(
                environment: environment,
                role: .rank,
                healthListener: .enabled(
                  hostname: "127.0.0.1", port: config.wireHealthPort
                ),
                roleLeaseAuthority: ownership.authority,
                logger: logger
              )
            }
          }
        }

        try await group.next()
        group.cancelAll()
      }
    } catch {
      runtimeError = error
    }
    try? await healthClient.shutdown()
    if let runtimeError { throw runtimeError }
  }

  private static func runCoordinatorLane(
    roleName: String,
    lane: IndexingWorkerLane,
    state: IndexingWorkerLaneState,
    store: any OperationsStore,
    diagnostics: PostgresRoleLeaseDiagnosticSampler,
    config: IndexingWorkerConfig,
    logger: Logger,
    operation: @Sendable @escaping (RoleLeaseOwnership) async throws -> Void
  ) async {
    await state.set(.starting, for: lane)
    guard
      let leaseConfiguration = try? RoleLeaseSupervisorConfiguration(
        role: roleName,
        ownerID: config.ownerID,
        leaseDuration: config.leaseDuration,
        renewInterval: config.leaseRenewInterval,
        standbyRetryInterval: config.standbyRetryInterval
      )
    else { return }

    let (events, continuation) = AsyncStream<RoleLeaseSupervisorEvent>.makeStream()
    let observer = Task {
      var lastSuccessfulControlLogAt = ContinuousClock.now
      var successfulRenewals = 0
      var maximumAttemptMilliseconds = 0.0
      var maximumPoolWaitMilliseconds = 0.0
      for await event in events {
        await state.record(event, for: lane)
        if case .controlAttempt(let observation) = event, observation.failure != nil {
          await diagnostics.capture(role: roleName)
        }
        if case .controlAttempt(let observation) = event, observation.failure == nil {
          guard observation.operation == .renew else { continue }
          successfulRenewals += 1
          maximumAttemptMilliseconds = max(maximumAttemptMilliseconds, observation.totalMilliseconds)
          maximumPoolWaitMilliseconds = max(maximumPoolWaitMilliseconds, observation.poolWaitMilliseconds ?? 0)
          let now = ContinuousClock.now
          guard lastSuccessfulControlLogAt.duration(to: now) >= .seconds(60) else { continue }
          logger.info("Indexing successful lease renewals", metadata: [
            "role": .string(roleName), "count": .stringConvertible(successfulRenewals),
            "maximum_attempt_ms": .stringConvertible(maximumAttemptMilliseconds),
            "maximum_pool_wait_ms": .stringConvertible(maximumPoolWaitMilliseconds),
          ])
          lastSuccessfulControlLogAt = now
          successfulRenewals = 0
          maximumAttemptMilliseconds = 0
          maximumPoolWaitMilliseconds = 0
          continue
        }
        if event != .acquiring && event != .contended {
          logger.info("Indexing role lifecycle", metadata: [
            "role": .string(roleName), "owner_id": .string(config.ownerID),
            "event": .string(String(describing: event)),
          ])
        }
      }
    }
    let supervisor = RoleLeaseSupervisor(
      store: store, configuration: leaseConfiguration,
      onEvent: { continuation.yield($0) })
    await supervisor.run { ownership in try await operation(ownership) }
    continuation.finish()
    await observer.value
  }

  private static func probeLanes(
    role: IndexingWorkerRole,
    path: String,
    config: IndexingWorkerConfig,
    state: IndexingWorkerLaneState,
    client: HTTPClient
  ) async throws {
    for lane in IndexingWorkerLane.allCases {
      guard let phase = await state.phase(for: lane) else {
        throw IndexingWorkerHealthError.laneNotStarted(lane)
      }
      switch (role, phase) {
      case (.coordinator, .standby):
        continue
      case (_, .running):
        let port = lane == .appView ? config.appViewHealthPort : config.wireHealthPort
        try await IndexingWorkerLocalHealthProbe.run(client: client, port: port, path: path)
      case (_, .starting):
        throw IndexingWorkerHealthError.laneNotStarted(lane)
      case (_, .restarting), (_, .stopping):
        throw IndexingWorkerHealthError.laneRestarting(lane)
      case (.projection, .standby):
        throw IndexingWorkerHealthError.laneNotStarted(lane)
      }
    }
  }
}

public enum IndexingWorkerRuntimeError: Error, Equatable {
  case missingDatabaseURL
  case controlEvidenceUnavailable
}
