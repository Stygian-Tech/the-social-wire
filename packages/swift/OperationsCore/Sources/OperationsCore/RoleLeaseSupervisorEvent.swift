/// Bounded lifecycle signals; database errors and query values are deliberately excluded.
public enum RoleLeaseSupervisorEvent: Sendable, Equatable {
  public enum StopReason: String, Sendable, Equatable {
    case completed, failed, cancelled, leaseLost
  }

  case acquiring
  case acquired(fencingToken: Int64)
  case contended
  case acquisitionFailed
  case validationFailed
  case operationStarted
  case renewalFailed
  case controlAttempt(RoleLeaseControlObservation)
  case renewalRetryScheduled(attempt: Int, failure: RoleLeaseFailure)
  case authorityExpired
  case operationStopping(reason: StopReason)
  case operationStopped(reason: StopReason)
  case releasing
  case released
  case releaseFailed
}
