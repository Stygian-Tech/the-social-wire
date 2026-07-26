import Foundation
import Logging
import OperationsCore

/// Coalesces high-frequency heartbeats/checkpoints into bounded durable SSE events.
actor OperationsEvidenceChangeMonitor {
  /// Leaves three and a half seconds of the five-second live visibility SLO for SSE delivery,
  /// request scheduling, and the route-aware refetch.
  static let defaultPollIntervalSeconds: TimeInterval = 1.5

  private let store: any OperationsStore
  private let logger: Logger
  private let pollInterval: Duration
  private let serviceRefreshInterval: TimeInterval
  private var serviceSignatures: [String: String] = [:]
  private var serviceEmittedAt: [String: Date] = [:]
  private var ingestionVersions: [String: Int] = [:]

  init(
    store: any OperationsStore,
    logger: Logger,
    pollInterval: Duration = .seconds(defaultPollIntervalSeconds),
    serviceRefreshInterval: TimeInterval = 30
  ) {
    self.store = store
    self.logger = logger
    self.pollInterval = pollInterval
    self.serviceRefreshInterval = serviceRefreshInterval
  }

  func runForever() async {
    while !Task.isCancelled {
      await runOnce(at: Date())
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        break
      }
    }
    // Capture the last committed source/service watermark when shutdown interrupts a burst.
    await runOnce(at: Date())
  }

  func runOnce(at now: Date) async {
    do {
      let services = try await store.listServiceStates()
      let streams = try await store.listStreamStates()
      try await emitServices(services, at: now)
      try await emitStreams(streams, at: now)
    } catch {
      // Retain the last emitted signatures. A database failure must not manufacture
      // fresh evidence; the previous events and heartbeats will naturally expire.
      logger.warning(
        "Operations evidence event coalescing failed",
        metadata: ["error_type": .string(OperationsRedactor.errorCategory(error))])
    }
  }

  private func emitServices(_ states: [OperationsServiceState], at now: Date) async throws {
    let liveKeys = Set(states.map(Self.serviceKey))
    for expiredKey in Set(serviceSignatures.keys).subtracting(liveKeys) {
      _ = try await store.appendChangeEvent(
        eventType: "service.expired", entityType: "service", entityId: expiredKey,
        payload: ["accuracy": "unavailable", "reason": "heartbeat_expired"], at: now)
      serviceSignatures.removeValue(forKey: expiredKey)
      serviceEmittedAt.removeValue(forKey: expiredKey)
    }

    for state in states {
      let key = Self.serviceKey(state)
      let signature = Self.serviceSignature(state)
      let changed = serviceSignatures[key] != signature
      let refreshDue = serviceEmittedAt[key].map {
        now.timeIntervalSince($0) >= serviceRefreshInterval
      } ?? true
      guard changed || refreshDue else { continue }
      _ = try await store.appendChangeEvent(
        eventType: "service.update", entityType: "service", entityId: key,
        payload: [
          "liveness": state.liveness.rawValue,
          "readiness": state.readiness.rawValue,
          "freshness": state.freshness.rawValue,
          "completeness": state.completeness.rawValue,
          "heartbeatAt": state.heartbeatAt.ISO8601Format(),
          "dependencies": state.dependencyState.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ";"),
        ], at: now)
      serviceSignatures[key] = signature
      serviceEmittedAt[key] = now
    }
  }

  private func emitStreams(_ states: [IngestionStreamState], at now: Date) async throws {
    for state in states where ingestionVersions[state.source] != state.version {
      _ = try await store.appendChangeEvent(
        eventType: "ingestion.update", entityType: "ingestion", entityId: state.source,
        payload: [
          "connectionState": state.connectionState.rawValue,
          "version": String(state.version),
          "heartbeatAt": state.heartbeatAt.ISO8601Format(),
          "transportHeartbeatAt": state.transportHeartbeatAt?.ISO8601Format() ?? "",
          "lastIndexedMutationAt": state.lastIndexedMutationAt?.ISO8601Format() ?? "",
          "projectionWatermark": state.projectionWatermark ?? "",
          "validationWatermark": state.validationWatermark ?? "",
        ], at: now)
      ingestionVersions[state.source] = state.version
    }
  }

  private static func serviceKey(_ state: OperationsServiceState) -> String {
    "\(state.service):\(state.instanceId)"
  }

  private static func serviceSignature(_ state: OperationsServiceState) -> String {
    [
      state.liveness.rawValue, state.readiness.rawValue, state.freshness.rawValue,
      state.completeness.rawValue,
      state.dependencyState.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: ";"),
    ].joined(separator: "|")
  }
}
