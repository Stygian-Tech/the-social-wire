import Foundation

actor WireWorkerHealthState {
  private(set) var lastSuccessfulCycleAt: Date?
  private(set) var lastGenerationFailure: String?
  private(set) var lastGenerationDurationMilliseconds: Double?
  private(set) var lastGraphMaintenanceAt: Date?
  private(set) var lastGraphMaintenanceFailure: String?
  private(set) var lastGraphMaintenanceDurationMilliseconds: Double?
  private(set) var drainStartedAt: Date?
  private(set) var lastSuccessfulDrainAt: Date?
  private(set) var lastDrainFailure: String?
  private(set) var cleanupStartedAt: Date?
  private(set) var lastSuccessfulCleanupAt: Date?
  private(set) var lastCleanupFailure: String?
  private(set) var lastCleanupDeletedCount = 0

  func recordGenerationSuccess(at: Date, durationMilliseconds: Double? = nil) {
    lastSuccessfulCycleAt = at
    lastGenerationDurationMilliseconds = durationMilliseconds
    lastGenerationFailure = nil
  }

  func recordGraphSuccess(at: Date, durationMilliseconds: Double) {
    lastGraphMaintenanceAt = at
    lastGraphMaintenanceDurationMilliseconds = durationMilliseconds
    lastGraphMaintenanceFailure = nil
  }

  func recordGraphFailure(_ error: Error) {
    lastGraphMaintenanceFailure = String(reflecting: error)
  }

  func recordGenerationFailure(_ error: Error) {
    lastGenerationFailure = String(reflecting: error)
  }

  func recordDrainStarted(at: Date) {
    drainStartedAt = at
  }

  func recordDrainSuccess(at: Date) {
    drainStartedAt = nil
    lastSuccessfulDrainAt = at
    lastDrainFailure = nil
  }

  func recordDrainFailure(_ error: Error) {
    drainStartedAt = nil
    lastDrainFailure = String(reflecting: error)
  }

  func recordCleanupStarted(at: Date) { cleanupStartedAt = at }
  func recordCleanupSuccess(at: Date, deleted: Int) {
    cleanupStartedAt = nil
    lastSuccessfulCleanupAt = at
    lastCleanupFailure = nil
    lastCleanupDeletedCount = deleted
  }
  func recordCleanupFailure(_ error: Error) {
    cleanupStartedAt = nil
    lastCleanupFailure = String(reflecting: error)
  }

  func isCleanupReady(at now: Date, maximumSuccessAge: TimeInterval, maximumOperationAge: TimeInterval) -> Bool {
    guard lastCleanupFailure == nil else { return false }
    if let cleanupStartedAt { return now.timeIntervalSince(cleanupStartedAt) <= maximumOperationAge }
    guard let lastSuccessfulCleanupAt else { return false }
    return now.timeIntervalSince(lastSuccessfulCleanupAt) <= maximumSuccessAge
  }

  func isGenerationReady(at now: Date, maximumCycleAge: TimeInterval) -> Bool {
    guard lastGenerationFailure == nil, let lastSuccessfulCycleAt else { return false }
    return now.timeIntervalSince(lastSuccessfulCycleAt) <= maximumCycleAge
  }

  func isDrainReady(
    at now: Date,
    maximumSuccessAge: TimeInterval,
    maximumOperationAge: TimeInterval
  ) -> Bool {
    guard lastDrainFailure == nil else { return false }
    if let drainStartedAt {
      return now.timeIntervalSince(drainStartedAt) <= maximumOperationAge
    }
    guard let lastSuccessfulDrainAt else { return false }
    return now.timeIntervalSince(lastSuccessfulDrainAt) <= maximumSuccessAge
  }

  func isReady(
    at now: Date,
    maximumCycleAge: TimeInterval,
    maximumDrainSuccessAge: TimeInterval,
    maximumDrainOperationAge: TimeInterval
  ) -> Bool {
    isGenerationReady(at: now, maximumCycleAge: maximumCycleAge)
      && isDrainReady(
        at: now,
        maximumSuccessAge: maximumDrainSuccessAge,
        maximumOperationAge: maximumDrainOperationAge
      )
  }
}
