public enum ThinAppViewWorkerRole: String, CaseIterable, Sendable, Equatable {
  case combined
  case projection
  case coordinator
}

public struct ThinAppViewWorkerRuntimePlan: Sendable, Equatable {
  public let runsLegacySubscriber: Bool
  public let runsInboxProjection: Bool
  public let runsProjectionRepair: Bool
  public let runsTapConsumer: Bool
  public let runsTtlCleanup: Bool
  public let runsProactiveBackfill: Bool
  public let runsRecovery: Bool
  public let runsRssPolling: Bool
  public let runsTelemetry: Bool
  public let runsHeartbeat: Bool

  public init(role: ThinAppViewWorkerRole) {
    switch role {
    case .combined:
      runsLegacySubscriber = true
      runsInboxProjection = true
      runsProjectionRepair = true
      runsTapConsumer = true
      runsTtlCleanup = true
      runsProactiveBackfill = true
      runsRecovery = true
      runsRssPolling = true
    case .projection:
      runsLegacySubscriber = false
      runsInboxProjection = true
      runsProjectionRepair = true
      runsTapConsumer = false
      runsTtlCleanup = false
      runsProactiveBackfill = false
      runsRecovery = false
      runsRssPolling = false
    case .coordinator:
      runsLegacySubscriber = false
      runsInboxProjection = false
      runsProjectionRepair = false
      runsTapConsumer = true
      runsTtlCleanup = true
      runsProactiveBackfill = true
      runsRecovery = true
      runsRssPolling = true
    }
    runsTelemetry = true
    runsHeartbeat = true
  }
}
