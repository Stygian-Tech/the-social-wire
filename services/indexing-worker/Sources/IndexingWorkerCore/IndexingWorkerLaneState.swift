import Foundation

public enum IndexingWorkerLane: String, CaseIterable, Sendable, Equatable {
  case appView = "appview"
  case wire
}

public enum IndexingWorkerLanePhase: String, Sendable, Equatable {
  case starting
  case running
  case standby
  case restarting
}

public actor IndexingWorkerLaneState {
  private var phases: [IndexingWorkerLane: IndexingWorkerLanePhase] = [:]

  public init() {}

  public func set(_ phase: IndexingWorkerLanePhase, for lane: IndexingWorkerLane) {
    phases[lane] = phase
  }

  public func phase(for lane: IndexingWorkerLane) -> IndexingWorkerLanePhase? {
    phases[lane]
  }

  public func snapshot() -> [IndexingWorkerLane: IndexingWorkerLanePhase] {
    phases
  }
}
