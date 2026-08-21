import Foundation

enum WireWorkerCycleOutcome: Equatable, Sendable {
  case off
  case generated(id: UUID, itemCount: Int, activated: Bool)
}
