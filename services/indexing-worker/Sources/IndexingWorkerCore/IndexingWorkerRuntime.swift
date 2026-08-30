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
    logger: Logger
  ) async throws {
    guard let databaseURL = environment["DATABASE_URL"], !databaseURL.isEmpty else {
      throw IndexingWorkerRuntimeError.missingDatabaseURL
    }
    let appEnvironment = try OperationsConfiguration.requireEnvironment(environment)
    let operationsConfiguration = OperationsConfiguration.fromEnvironment(environment)
    let postgresConfiguration = try makePostgresConfig(from: databaseURL, logger: logger)
    let pool = PostgresClient(configuration: postgresConfiguration, backgroundLogger: logger)
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
        group.addTask {
          try await IndexingWorkerHealthServer.run(
            role: config.role,
            startupProbe: {
              try await operationsStore.ping()
              try await probeLanes(
                role: config.role,
                path: "/startupz",
                config: config,
                state: laneState,
                client: healthClient
              )
            },
            readinessProbe: {
              try await operationsStore.ping()
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
              config: config
            ) {
              try await AppViewWorkerHost.run(
                environment: environment,
                role: .coordinator,
                serviceName: "coordinator-appview",
                healthListener: .enabled(
                  hostname: "127.0.0.1", port: config.appViewHealthPort
                ),
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
              config: config
            ) {
              try await WireWorkerHost.run(
                environment: environment,
                role: .rank,
                healthListener: .enabled(
                  hostname: "127.0.0.1", port: config.wireHealthPort
                ),
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
    config: IndexingWorkerConfig,
    operation: @Sendable @escaping () async throws -> Void
  ) async {
    await state.set(.standby, for: lane)
    guard
      let leaseConfiguration = try? RoleLeaseSupervisorConfiguration(
        role: roleName,
        ownerID: config.ownerID,
        leaseDuration: config.leaseDuration,
        renewInterval: config.leaseRenewInterval,
        standbyRetryInterval: config.standbyRetryInterval
      )
    else { return }

    let supervisor = RoleLeaseSupervisor(store: store, configuration: leaseConfiguration)
    await supervisor.run { _ in
      await state.set(.running, for: lane)
      do {
        try await operation()
      } catch {
        await state.set(.standby, for: lane)
        throw error
      }
      await state.set(.standby, for: lane)
    }
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
      case (_, .restarting):
        throw IndexingWorkerHealthError.laneRestarting(lane)
      case (.projection, .standby):
        throw IndexingWorkerHealthError.laneNotStarted(lane)
      }
    }
  }
}

public enum IndexingWorkerRuntimeError: Error, Equatable {
  case missingDatabaseURL
}
