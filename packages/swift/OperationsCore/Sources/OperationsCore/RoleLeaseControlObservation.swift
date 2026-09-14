public struct RoleLeaseControlObservation: Sendable, Equatable {
  public enum Operation: String, Sendable { case acquire, validate, renew, release }
  public let operation: Operation
  public let failure: RoleLeaseFailure?
  public let totalMilliseconds: Double
  public let poolWaitMilliseconds: Double?
  public let databaseMilliseconds: Double?
  public let schedulingDelayMilliseconds: Double?
  public let remainingAuthorityMilliseconds: Double?
  public let retry: Int
}
