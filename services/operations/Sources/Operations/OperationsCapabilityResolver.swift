import Foundation
import Logging
import OperationsCore

struct OperationsCapabilityResolver: Sendable {
  static let eventStreamRetryMilliseconds = 1_000
  static let fallbackPollMilliseconds = 2_500

  static let tapVerifiedResyncDisabledReason =
    "Pinned Tap has no safe resync API or complete delete and job-watermark verification."

  let store: any OperationsStore
  let config: OperationsConfiguration

  func resolve(at now: Date = Date()) async -> OperationsCapabilities {
    let eventStreamOperational = (try? await store.changeEventCursorBounds()) != nil
    let states = (try? await store.listServiceStates()) ?? []
    let worker = states
      .filter({ $0.service == "appview-worker" })
      .max(by: { $0.heartbeatAt < $1.heartbeatAt })

    let fingerprintReady = config.backfillFingerprintSecret != nil
    let prerequisiteReason: String?
    if !config.recoveryEnabled {
      prerequisiteReason = "Operations recovery is disabled by the environment release gate."
    } else if !fingerprintReady {
      prerequisiteReason = "The backfill fingerprint signing secret is unavailable."
    } else if worker == nil {
      prerequisiteReason = "No AppView worker capability evidence is available."
    } else if let worker, now.timeIntervalSince(worker.heartbeatAt) > 15 {
      prerequisiteReason = "The AppView worker capability evidence has expired."
    } else if let worker,
      worker.dependencyState["operations_database"] != "ready"
        || worker.dependencyState["appview_database"] != "ready"
    {
      prerequisiteReason = "The AppView worker database dependencies are not ready."
    } else {
      prerequisiteReason = nil
    }

    let jetstreamReplay = modeCapability(
      worker: worker, key: "jetstream_replay", acceptedValue: "enabled_unverified",
      unavailableDescription: "Jetstream replay")
    let pdsReconciliation = modeCapability(
      worker: worker, key: "pds_reconciliation", acceptedValue: "enabled_diagnostic_only",
      unavailableDescription: "PDS reconciliation")
    let gatedJetstream = prerequisiteReason.map {
      OperationsCapability(enabled: false, disabledReason: $0)
    } ?? jetstreamReplay
    let gatedPDS = prerequisiteReason.map {
      OperationsCapability(enabled: false, disabledReason: $0)
    } ?? pdsReconciliation
    let globalRecoveryReady = gatedJetstream.enabled || gatedPDS.enabled
    let recoveryReason = globalRecoveryReady ? nil
      : prerequisiteReason
        ?? "No worker-advertised recovery mode is currently available."

    let alertReady = config.alertDeliveryEnabled
      && config.webhookURL != nil && config.webhookSecret != nil
    let alertReason: String?
    if !config.alertDeliveryEnabled {
      alertReason = "Alert delivery is disabled by configuration."
    } else if config.webhookURL == nil || config.webhookSecret == nil {
      alertReason = "Alert delivery webhook configuration is incomplete."
    } else {
      alertReason = nil
    }

    return OperationsCapabilities(
      environment: config.environment,
      telemetry: OperationsCapability(
        enabled: config.enabled,
        disabledReason: config.enabled ? nil : "Operations telemetry is disabled by configuration."),
      recovery: OperationsCapability(enabled: globalRecoveryReady, disabledReason: recoveryReason),
      recoveryModes: OperationsRecoveryModeCapabilities(
        tapVerifiedResync: OperationsCapability(
          enabled: false, disabledReason: Self.tapVerifiedResyncDisabledReason),
        jetstreamReplay: gatedJetstream,
        pdsReconciliation: gatedPDS),
      alertDelivery: OperationsCapability(enabled: alertReady, disabledReason: alertReason),
      eventStream: OperationsEventStreamCapability(
        enabled: eventStreamOperational,
        disabledReason: eventStreamOperational
          ? nil : "The durable ordered event log is unavailable.",
        path: "/v1/operations/events/stream",
        retryMilliseconds: Self.eventStreamRetryMilliseconds,
        fallbackPollMilliseconds: Self.fallbackPollMilliseconds),
      generatedAt: now)
  }

  private func modeCapability(
    worker: OperationsServiceState?,
    key: String,
    acceptedValue: String,
    unavailableDescription: String
  ) -> OperationsCapability {
    guard let advertised = worker?.dependencyState[key] else {
      return OperationsCapability(
        enabled: false,
        disabledReason: "The worker did not advertise \(unavailableDescription) capability evidence.")
    }
    guard advertised == acceptedValue else {
      return OperationsCapability(
        enabled: false,
        disabledReason: "\(unavailableDescription) is unavailable: \(advertised).")
    }
    return OperationsCapability(enabled: true)
  }
}

actor OperationsCapabilityMonitor {
  private let resolver: OperationsCapabilityResolver
  private let store: any OperationsStore
  private let logger: Logger
  private var lastPayload: [String: String]?

  init(resolver: OperationsCapabilityResolver, store: any OperationsStore, logger: Logger) {
    self.resolver = resolver
    self.store = store
    self.logger = logger
  }

  func runForever() async {
    while !Task.isCancelled {
      do {
        let capabilities = await resolver.resolve()
        let payload = Self.payload(capabilities)
        if payload != lastPayload {
          _ = try await store.appendChangeEvent(
            eventType: "capability.changed", entityType: "capability",
            entityId: capabilities.environment, payload: payload, at: capabilities.generatedAt)
          lastPayload = payload
        }
      } catch {
        logger.warning(
          "Operations capability event export failed",
          metadata: ["error_type": .string(OperationsRedactor.errorCategory(error))])
      }
      try? await Task.sleep(for: .seconds(5))
    }
  }

  private static func payload(_ value: OperationsCapabilities) -> [String: String] {
    [
      "telemetry": String(value.telemetry.enabled),
      "recovery": String(value.recovery.enabled),
      "tapVerifiedResync": String(value.recoveryModes.tapVerifiedResync.enabled),
      "jetstreamReplay": String(value.recoveryModes.jetstreamReplay.enabled),
      "pdsReconciliation": String(value.recoveryModes.pdsReconciliation.enabled),
      "alertDelivery": String(value.alertDelivery.enabled),
      "eventStream": String(value.eventStream.enabled),
    ]
  }
}
