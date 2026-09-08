import Foundation

public enum ReadStateSyncFailure: Error, Sendable {
  case conflict
  case rateLimited(until: Date)
  case accountChanged
  case corruptOutbox
  case reauthorizationRequired
}
