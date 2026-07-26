import Foundation
import Logging
import OperationsCore

/// Service-specific evidence used to publish one Operations heartbeat.
///
/// A service must probe its own required dependencies and freshness source. The heartbeat job adds
/// the Operations database probe and optional local telemetry-buffer evidence; it never borrows
/// Jetstream content arrival as freshness for an unrelated service.
public struct OperationsServiceProbeResult: Sendable {
  public let liveness: OperationsHealthState
  public let readiness: OperationsHealthState
  public let freshness: OperationsHealthState
  public let completeness: OperationsHealthState
  public let dependencyState: [String: String]
  public let requiredDependencyKeys: Set<String>
  public let observedAt: Date
  public let validUntil: Date

  public init(
    liveness: OperationsHealthState,
    readiness: OperationsHealthState,
    freshness: OperationsHealthState,
    completeness: OperationsHealthState,
    dependencyState: [String: String],
    requiredDependencyKeys: Set<String>? = nil,
    observedAt: Date,
    validUntil: Date
  ) {
    self.liveness = liveness
    self.readiness = readiness
    self.freshness = freshness
    self.completeness = completeness
    self.dependencyState = dependencyState
    self.requiredDependencyKeys = requiredDependencyKeys ?? Set(dependencyState.keys)
    self.observedAt = observedAt
    self.validUntil = validUntil
  }
}

public typealias OperationsServiceDependencyProbe =
  @Sendable () async throws -> OperationsServiceProbeResult

public struct OperationsHeartbeatJob: Sendable {
  let store: any OperationsStore
  let service: String
  let environment: String
  let instanceId: String
  let dependencyProbe: OperationsServiceDependencyProbe?
  let telemetry: OperationsTelemetryBuffer?
  let logger: Logger

  public init(
    store: any OperationsStore,
    service: String,
    environment: String,
    instanceId: String,
    dependencyProbe: OperationsServiceDependencyProbe? = nil,
    telemetry: OperationsTelemetryBuffer? = nil,
    logger: Logger
  ) {
    self.store = store
    self.service = service
    self.environment = environment
    self.instanceId = instanceId
    self.dependencyProbe = dependencyProbe
    self.telemetry = telemetry
    self.logger = logger
  }

  public func runForever() async {
    let startedAt = Date()
    while !Task.isCancelled {
      do {
        try await runOnce(startedAt: startedAt, now: { Date() })
      } catch {
        // A failed Operations database probe cannot safely publish a green replacement heartbeat.
        // The last evidence is intentionally allowed to expire to Unknown.
        logger.warning(
          "Operations heartbeat failed",
          metadata: ["error_type": .string(OperationsRedactor.errorCategory(error))]
        )
      }
      try? await Task.sleep(for: .seconds(5))
    }
  }

  func runOnce(startedAt: Date, at now: Date) async throws {
    try await runOnce(startedAt: startedAt, now: { now })
  }

  func runOnce(
    startedAt: Date,
    now: @Sendable () -> Date
  ) async throws {
    try await store.ping()

    let evaluated = await evaluateProbe(now: now)
    var dependencies = evaluated.dependencyState
    dependencies["operations_database"] = "ready"
    var freshness = evaluated.freshness
    var completeness = evaluated.completeness
    if let telemetry {
      let snapshot = await telemetry.snapshot()
      let telemetryEvidence = Self.telemetryEvidence(snapshot, at: now())
      dependencies.merge(telemetryEvidence.dependencyState) { _, telemetryValue in
        telemetryValue
      }
      if telemetryEvidence.freshnessUncertain {
        freshness = Self.unknownIfHealthy(freshness)
      } else if telemetryEvidence.exportFailureObserved {
        freshness = Self.downgradeHealthy(freshness)
      }
      if telemetryEvidence.completenessUncertain {
        completeness = Self.unknownIfHealthy(completeness)
      } else if telemetryEvidence.dropObserved {
        completeness = Self.downgradeHealthy(completeness)
      }
    }
    try await store.upsertServiceState(
      OperationsServiceState(
        service: service,
        environment: environment,
        instanceId: instanceId,
        liveness: evaluated.liveness,
        readiness: evaluated.readiness,
        freshness: freshness,
        completeness: completeness,
        dependencyState: dependencies,
        version: ProcessInfo.processInfo.environment["FLY_IMAGE_REF"],
        startedAt: startedAt,
        heartbeatAt: now()
      )
    )
  }

  private func evaluateProbe(
    now: @Sendable () -> Date
  ) async -> OperationsServiceProbeResult {
    guard let dependencyProbe else {
      return unknownProbeResult(reason: "missing", at: now())
    }

    do {
      let result = try await dependencyProbe()
      let evaluatedAt = now()
      guard result.observedAt <= evaluatedAt, result.validUntil > evaluatedAt else {
        var dependencies = result.dependencyState
        dependencies["service_probe"] = "expired"
        return OperationsServiceProbeResult(
          liveness: .unknown,
          readiness: .unknown,
          freshness: .unknown,
          completeness: .unknown,
          dependencyState: dependencies,
          requiredDependencyKeys: result.requiredDependencyKeys,
          observedAt: result.observedAt,
          validUntil: result.validUntil
        )
      }

      guard !result.requiredDependencyKeys.isEmpty else {
        return unknownProbeResult(reason: "missing_dependencies", at: evaluatedAt)
      }
      let dependenciesReady = result.requiredDependencyKeys.allSatisfy {
        guard let value = result.dependencyState[$0] else { return false }
        return value == "ready" || value == "healthy"
      }
      guard dependenciesReady else {
        var dependencies = result.dependencyState
        dependencies["service_probe"] = "degraded"
        return OperationsServiceProbeResult(
          liveness: Self.downgradeHealthy(result.liveness),
          readiness: Self.downgradeHealthy(result.readiness),
          freshness: Self.downgradeHealthy(result.freshness),
          completeness: Self.downgradeHealthy(result.completeness),
          dependencyState: dependencies,
          requiredDependencyKeys: result.requiredDependencyKeys,
          observedAt: result.observedAt,
          validUntil: result.validUntil
        )
      }

      var dependencies = result.dependencyState
      dependencies["service_probe"] = "ready"
      return OperationsServiceProbeResult(
        liveness: result.liveness,
        readiness: result.readiness,
        freshness: result.freshness,
        completeness: result.completeness,
        dependencyState: dependencies,
        requiredDependencyKeys: result.requiredDependencyKeys,
        observedAt: result.observedAt,
        validUntil: result.validUntil
      )
    } catch {
      let evaluatedAt = now()
      return OperationsServiceProbeResult(
        liveness: .degraded,
        readiness: .degraded,
        freshness: .unknown,
        completeness: .unknown,
        dependencyState: [
          "service_probe": "failed:\(OperationsRedactor.errorCategory(error))"
        ],
        observedAt: evaluatedAt,
        validUntil: evaluatedAt
      )
    }
  }

  private func unknownProbeResult(reason: String, at now: Date) -> OperationsServiceProbeResult {
    OperationsServiceProbeResult(
      liveness: .unknown,
      readiness: .unknown,
      freshness: .unknown,
      completeness: .unknown,
      dependencyState: ["service_probe": reason],
      observedAt: now,
      validUntil: now
    )
  }

  private static func downgradeHealthy(_ state: OperationsHealthState) -> OperationsHealthState {
    state == .healthy ? .degraded : state
  }

  private static func unknownIfHealthy(_ state: OperationsHealthState) -> OperationsHealthState {
    state == .healthy ? .unknown : state
  }

  static func telemetryEvidence(
    _ snapshot: OperationsTelemetryBufferSnapshot,
    at observedAt: Date
  ) -> OperationsTelemetryHeartbeatEvidence {
    let formatter = ISO8601DateFormatter()
    var dependencies = [
      "telemetry_queue_depth": String(snapshot.queueDepth),
      "telemetry_in_flight": String(snapshot.inFlightCount),
      "telemetry_queue_capacity": String(snapshot.capacity),
      "telemetry_dropped_total": String(snapshot.droppedCount),
      "telemetry_consecutive_failures": String(snapshot.consecutiveFailures),
      "telemetry_last_successful_export_at": snapshot.lastSuccessfulExportAt.map(formatter.string)
        ?? "none",
      "telemetry_snapshot_observed_at": formatter.string(from: observedAt),
    ]

    let occupied = snapshot.queueDepth.addingReportingOverflow(snapshot.inFlightCount)
    let structurallyValid = snapshot.queueDepth >= 0
      && snapshot.inFlightCount >= 0
      && snapshot.capacity > 0
      && snapshot.droppedCount >= 0
      && snapshot.consecutiveFailures >= 0
      && !occupied.overflow
      && occupied.partialValue <= snapshot.capacity

    var lastExportTimeValid = true
    if let lastSuccessfulExportAt = snapshot.lastSuccessfulExportAt {
      let age = observedAt.timeIntervalSince(lastSuccessfulExportAt)
      if age >= 0 {
        dependencies["telemetry_last_export_age_seconds"] = String(
          format: "%.3f",
          locale: Locale(identifier: "en_US_POSIX"),
          age
        )
      } else {
        dependencies["telemetry_last_export_age_seconds"] = "invalid_future"
        lastExportTimeValid = false
      }
    } else {
      dependencies["telemetry_last_export_age_seconds"] = "unknown"
    }

    guard structurallyValid, lastExportTimeValid else {
      dependencies["telemetry_exporter"] = "unknown_invalid_snapshot"
      return OperationsTelemetryHeartbeatEvidence(
        dependencyState: dependencies,
        exportFailureObserved: false,
        dropObserved: false,
        freshnessUncertain: true,
        completenessUncertain: true
      )
    }

    let exportFailureObserved = snapshot.consecutiveFailures > 0
    let dropObserved = snapshot.droppedCount > 0
    if exportFailureObserved || dropObserved {
      dependencies["telemetry_exporter"] = "degraded"
    } else if snapshot.inFlightCount > 0 {
      dependencies["telemetry_exporter"] = "exporting"
    } else if snapshot.queueDepth > 0 {
      dependencies["telemetry_exporter"] = "queued"
    } else if snapshot.lastSuccessfulExportAt == nil {
      dependencies["telemetry_exporter"] = "idle_no_export_yet"
    } else {
      dependencies["telemetry_exporter"] = "idle"
    }

    return OperationsTelemetryHeartbeatEvidence(
      dependencyState: dependencies,
      exportFailureObserved: exportFailureObserved,
      dropObserved: dropObserved,
      freshnessUncertain: false,
      completenessUncertain: false
    )
  }
}

struct OperationsTelemetryHeartbeatEvidence: Sendable {
  let dependencyState: [String: String]
  let exportFailureObserved: Bool
  let dropObserved: Bool
  let freshnessUncertain: Bool
  let completenessUncertain: Bool
}
