import Foundation
import OperationsCore

public enum IndexingWorkerLane: String, CaseIterable, Sendable, Equatable {
  case appView = "appview"
  case wire
}

public enum IndexingWorkerLanePhase: String, Sendable, Equatable {
  case starting
  case running
  case standby
  case restarting
  case stopping
}

public actor IndexingWorkerLaneState {
  private var phases: [IndexingWorkerLane: IndexingWorkerLanePhase] = [:]
  private var stoppingSince: [IndexingWorkerLane: Date] = [:]
  private var controlObservedAt: [IndexingWorkerLane: Date] = [:]

  public init() {}

  public func set(_ phase: IndexingWorkerLanePhase, for lane: IndexingWorkerLane) {
    phases[lane] = phase
    if phase != .stopping { stoppingSince[lane] = nil }
  }

  func record(_ event: RoleLeaseSupervisorEvent, for lane: IndexingWorkerLane, at: Date = Date()) {
    switch event {
    case .acquiring: break
    case .acquired:
      controlObservedAt[lane] = at
      set(.starting, for: lane)
    case .operationStarted: set(.running, for: lane)
    case .contended:
      controlObservedAt[lane] = at
      set(.standby, for: lane)
    case .controlAttempt(let observation):
      if observation.failure == nil { controlObservedAt[lane] = at }
    case .renewalRetryScheduled: break
    case .authorityExpired:
      phases[lane] = .stopping
      if stoppingSince[lane] == nil { stoppingSince[lane] = at }
    case .operationStopping, .operationStopped, .releasing:
      phases[lane] = .stopping
      if stoppingSince[lane] == nil { stoppingSince[lane] = at }
    case .acquisitionFailed, .validationFailed, .released, .releaseFailed:
      set(.restarting, for: lane)
    case .renewalFailed: break
    }
  }

  func unresponsiveLane(at now: Date = Date(), grace: TimeInterval = 30) -> IndexingWorkerLane? {
    IndexingWorkerLane.allCases.first { lane in
      stoppingSince[lane].map { now.timeIntervalSince($0) >= grace } ?? false
    }
  }

  public func phase(for lane: IndexingWorkerLane) -> IndexingWorkerLanePhase? {
    phases[lane]
  }

  public func snapshot() -> [IndexingWorkerLane: IndexingWorkerLanePhase] {
    phases
  }

  /// Health requests consume recent control evidence rather than competing with renewals.
  func hasRecentControlEvidence(at now: Date = Date(), maximumAge: TimeInterval = 30) -> Bool {
    IndexingWorkerLane.allCases.allSatisfy { lane in
      guard let observedAt = controlObservedAt[lane] else { return false }
      let age = now.timeIntervalSince(observedAt)
      return age >= 0 && age <= maximumAge
    }
  }
}
