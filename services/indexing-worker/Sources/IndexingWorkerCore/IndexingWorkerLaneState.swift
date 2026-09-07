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

  public init() {}

  public func set(_ phase: IndexingWorkerLanePhase, for lane: IndexingWorkerLane) {
    phases[lane] = phase
    if phase != .stopping { stoppingSince[lane] = nil }
  }

  func record(_ event: RoleLeaseSupervisorEvent, for lane: IndexingWorkerLane, at: Date = Date()) {
    switch event {
    case .acquiring: break
    case .acquired: set(.starting, for: lane)
    case .operationStarted: set(.running, for: lane)
    case .contended: set(.standby, for: lane)
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
}
