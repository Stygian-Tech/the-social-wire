import Foundation

public enum ReadStateSyncFailure: LocalizedError, Sendable {
  case migrationScopeConflict
  case projectionNotReady
  case conflict
  case rateLimited(until: Date)
  case accountChanged
  case corruptOutbox
  case reauthorizationRequired

  public var errorDescription: String? {
    switch self {
    case .migrationScopeConflict:
      "Overlapping publications have different read boundaries. Your existing history has not changed. If you want all articles in those publications marked read, use Mark All As Read, then retry. If the conflict remains, those publications need further reconciliation before migration can continue."
    case .projectionNotReady:
      "Restoring Read History. Your PDS history and pending changes remain protected. Please try again shortly."
    default: nil
    }
  }
}
