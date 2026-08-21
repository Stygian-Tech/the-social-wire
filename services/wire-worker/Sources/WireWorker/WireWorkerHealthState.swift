import Foundation

actor WireWorkerHealthState {
  private(set) var lastSuccessfulCycleAt: Date?
  private(set) var lastGenerationFailure: String?
  private(set) var drainStartedAt: Date?
  private(set) var lastSuccessfulDrainAt: Date?
  private(set) var lastDrainFailure: String?

  func recordGenerationSuccess(at: Date) {
    lastSuccessfulCycleAt = at
    lastGenerationFailure = nil
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

  func isReady(
    at now: Date,
    maximumCycleAge: TimeInterval,
    maximumDrainSuccessAge: TimeInterval,
    maximumDrainOperationAge: TimeInterval
  ) -> Bool {
    guard lastGenerationFailure == nil, let lastSuccessfulCycleAt,
      now.timeIntervalSince(lastSuccessfulCycleAt) <= maximumCycleAge,
      lastDrainFailure == nil
    else { return false }
    if let drainStartedAt {
      return now.timeIntervalSince(drainStartedAt) <= maximumDrainOperationAge
    }
    guard let lastSuccessfulDrainAt else { return false }
    return now.timeIntervalSince(lastSuccessfulDrainAt) <= maximumDrainSuccessAge
  }
}
