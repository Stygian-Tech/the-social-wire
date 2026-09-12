import Foundation

public protocol RoleLeaseSupervisorTiming: Sendable {
  func now() async -> Date
  func monotonicNow() async -> TimeInterval
  func sleep(for interval: TimeInterval) async
}

public extension RoleLeaseSupervisorTiming {
  // Test clocks may derive both views from a single controlled timeline.
  func monotonicNow() async -> TimeInterval { await now().timeIntervalSince1970 }
}

public struct SystemRoleLeaseSupervisorTiming: RoleLeaseSupervisorTiming {
  private static let epoch = ContinuousClock.now
  public init() {}

  public func now() async -> Date { Date() }
  public func monotonicNow() async -> TimeInterval {
    let elapsed = Self.epoch.duration(to: .now).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  }

  public func sleep(for interval: TimeInterval) async {
    try? await Task.sleep(for: .seconds(interval))
  }
}

public enum RoleLeaseSupervisorError: Error, Sendable, Equatable {
  case invalidConfiguration
}

public struct RoleLeaseSupervisorConfiguration: Sendable, Equatable {
  public let role: String
  public let ownerID: String
  public let leaseDuration: TimeInterval
  public let renewInterval: TimeInterval
  public let standbyRetryInterval: TimeInterval

  public init(
    role: String,
    ownerID: String,
    leaseDuration: TimeInterval,
    renewInterval: TimeInterval,
    standbyRetryInterval: TimeInterval
  ) throws {
    guard !role.isEmpty, role.count <= 128,
      !ownerID.isEmpty, ownerID.count <= 255,
      leaseDuration.isFinite, leaseDuration > 5,
      renewInterval.isFinite, renewInterval > 0, renewInterval < leaseDuration - 5,
      standbyRetryInterval.isFinite, standbyRetryInterval > 0
    else { throw RoleLeaseSupervisorError.invalidConfiguration }
    self.role = role
    self.ownerID = ownerID
    self.leaseDuration = leaseDuration
    self.renewInterval = renewInterval
    self.standbyRetryInterval = standbyRetryInterval
  }
}

public struct RoleLeaseOwnership: Sendable {
  public let environment: String
  public let role: String
  public let ownerID: String
  public let fencingToken: Int64

  private let store: any RoleLeaseStoring

  init(lease: FencedRoleLease, store: any RoleLeaseStoring) {
    environment = lease.environment
    role = lease.role
    ownerID = lease.ownerID
    fencingToken = lease.fencingToken
    self.store = store
  }

  public var authority: RoleLeaseAuthority {
    RoleLeaseAuthority(environment: environment, role: role, ownerID: ownerID, fencingToken: fencingToken)
  }

  /// Runs one authority-owned side effect while holding the durable lease row fence.
  /// Call this at the commit boundary for work that must never overlap a successor.
  public func withFence(
    at: Date = Date(),
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    try await store.withRoleLeaseFence(
      role: role,
      ownerID: ownerID,
      fencingToken: fencingToken,
      at: at,
      operation: operation
    )
  }
}

public struct RoleLeaseSupervisor: Sendable {
  private let store: any RoleLeaseStoring
  private let configuration: RoleLeaseSupervisorConfiguration
  private let timing: any RoleLeaseSupervisorTiming
  private let onEvent: @Sendable (RoleLeaseSupervisorEvent) -> Void

  /// `onEvent` is synchronous and may run concurrently from renewal and operation tasks.
  /// Keep it nonblocking; an AsyncStream continuation can forward ordered signals to an actor.
  public init(
    store: any RoleLeaseStoring,
    configuration: RoleLeaseSupervisorConfiguration,
    timing: any RoleLeaseSupervisorTiming = SystemRoleLeaseSupervisorTiming(),
    onEvent: @escaping @Sendable (RoleLeaseSupervisorEvent) -> Void = { _ in }
  ) {
    self.store = store
    self.configuration = configuration
    self.timing = timing
    self.onEvent = onEvent
  }

  /// Failed control attempts never extend locally confirmed authority. The watchdog
  /// remains independent of the renewal query and cancels work before the DB expiry.
  public func run(
    operation: @Sendable @escaping (RoleLeaseOwnership) async throws -> Void
  ) async {
    while !Task.isCancelled {
      do {
        onEvent(.acquiring)
        let started = await timing.monotonicNow()
        let acquiredAt = await timing.now()
        if let lease = try await observe(.acquire, body: {
          try await store.acquireRoleLease(
            role: configuration.role, ownerID: configuration.ownerID,
            leaseUntil: acquiredAt.addingTimeInterval(configuration.leaseDuration), at: acquiredAt)
        }) {
          onEvent(.acquired(fencingToken: lease.fencingToken))
          await runOwned(lease: lease, acquiredStart: started, operation: operation)
        } else {
          onEvent(.contended)
        }
      } catch {
        onEvent(.acquisitionFailed)
      }
      guard !Task.isCancelled else { return }
      await timing.sleep(for: configuration.standbyRetryInterval)
    }
  }

  private func runOwned(
    lease: FencedRoleLease,
    acquiredStart: TimeInterval,
    operation: @Sendable @escaping (RoleLeaseOwnership) async throws -> Void
  ) async {
    let ownership = RoleLeaseOwnership(lease: lease, store: store)
    let authority = RoleLeaseAuthorityDeadline(deadline: safeDeadline(lease, started: acquiredStart))
    do {
      do {
        let validationTime = await timing.now()
        try await observe(.validate, authority: authority) {
          try await ownership.withFence(at: validationTime) {}
        }
        try await authority.check(at: timing.monotonicNow())
      } catch {
        onEvent(.validationFailed)
        throw error
      }
      try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask {
          try await withTaskCancellationHandler {
            do {
              try Task.checkCancellation()
              try await authority.check(at: timing.monotonicNow())
              onEvent(.operationStarted)
              try await operation(ownership)
              onEvent(.operationStopped(reason: Task.isCancelled ? .cancelled : .completed))
            } catch {
              let reason: RoleLeaseSupervisorEvent.StopReason =
                Task.isCancelled || error is CancellationError ? .cancelled : .failed
              onEvent(.operationStopped(reason: reason))
              throw error
            }
          } onCancel: {
            onEvent(.operationStopping(reason: .cancelled))
          }
        }
        group.addTask {
          do {
            try await renew(lease, authority: authority, firstStart: acquiredStart)
          } catch {
            if !Task.isCancelled {
              onEvent(.renewalFailed)
              onEvent(.operationStopping(reason: .leaseLost))
            }
            throw error
          }
        }
        group.addTask {
          while !Task.isCancelled {
            let now = await timing.monotonicNow()
            let remaining = await authority.remaining(at: now)
            if remaining <= 0 {
              onEvent(.authorityExpired)
              onEvent(.operationStopping(reason: .leaseLost))
              throw RoleLeaseFailure.authorityExpired
            }
            await timing.sleep(for: remaining)
          }
          throw CancellationError()
        }
        _ = try await group.next()
      }
    } catch {
      // Fail closed and join cancelled work before releasing or reacquiring.
    }
    let releasedAt = await timing.now()
    onEvent(.releasing)
    do {
      try await observe(.release, authority: authority) {
        try await store.releaseRoleLease(
          role: configuration.role, ownerID: configuration.ownerID,
          fencingToken: lease.fencingToken, at: releasedAt)
      }
      onEvent(.released)
    } catch {
      onEvent(.releaseFailed)
    }
  }

  private func safeDeadline(_ lease: FencedRoleLease, started: TimeInterval) -> TimeInterval {
    // Use the granted duration, never compare the database clock to the process clock.
    started + min(configuration.leaseDuration, lease.expiresAt.timeIntervalSince(lease.updatedAt)) - 5
  }

  private func renew(
    _ lease: FencedRoleLease, authority: RoleLeaseAuthorityDeadline, firstStart: TimeInterval
  ) async throws {
    var scheduled = firstStart + configuration.renewInterval
    while !Task.isCancelled {
      let delay = scheduled - (await timing.monotonicNow())
      if delay > 0 { await timing.sleep(for: delay) }
      try Task.checkCancellation()
      let cycleStart = await timing.monotonicNow()
      var retry = 0
      while true {
        try await authority.check(at: timing.monotonicNow())
        if retry > 0 {
          // Backoff may oversleep under pressure; recheck the complete attempt
          // budget after waking, not only before scheduling the retry.
          guard await authority.remaining(at: timing.monotonicNow()) > 3 else {
            throw RoleLeaseFailure.authorityExpired
          }
        }
        let started = await timing.monotonicNow()
        let at = await timing.now()
        do {
          let renewed = try await observe(
            .renew, authority: authority, schedulingDelay: max(0, cycleStart - scheduled), retry: retry
          ) {
            try await store.renewRoleLease(
              role: configuration.role, ownerID: configuration.ownerID, fencingToken: lease.fencingToken,
              leaseUntil: at.addingTimeInterval(configuration.leaseDuration), at: at)
          }
          try await authority.confirm(deadline: safeDeadline(renewed, started: started), at: timing.monotonicNow())
          break
        } catch {
          try Task.checkCancellation()
          let failure = RoleLeaseFailure.classify(error)
          let remaining = await authority.remaining(at: timing.monotonicNow())
          // One second backoff plus a complete three second control budget must fit
          // before the existing five second safety margin. No authority on guesses.
          guard failure.isTransient, retry < 2, remaining > 4 else { throw error }
          retry += 1
          onEvent(.renewalRetryScheduled(attempt: retry, failure: failure))
          await timing.sleep(for: 1)
        }
      }
      scheduled += configuration.renewInterval
      let finished = await timing.monotonicNow()
      if scheduled <= finished { scheduled = finished + configuration.renewInterval }
    }
    throw CancellationError()
  }

  private func observe<Value: Sendable>(
    _ operation: RoleLeaseControlObservation.Operation,
    authority: RoleLeaseAuthorityDeadline? = nil,
    schedulingDelay: TimeInterval? = nil,
    retry: Int = 0,
    body: @Sendable () async throws -> Value
  ) async throws -> Value {
    let started = await timing.monotonicNow()
    let metrics = RoleLeaseAttemptMetrics()
    let result: Result<Value, any Error>
    do {
      result = .success(try await RoleLeaseAttemptMetrics.$current.withValue(metrics) { try await body() })
    } catch {
      result = .failure(error)
    }
    let finished = await timing.monotonicNow()
    let failure: RoleLeaseFailure?
    switch result {
    case .success: failure = Task.isCancelled ? .cancelled : nil
    case .failure(let error): failure = Task.isCancelled ? .cancelled : RoleLeaseFailure.classify(error)
    }
    let snapshot = metrics.snapshot
    let remaining = await authority?.remaining(at: finished)
    onEvent(.controlAttempt(RoleLeaseControlObservation(
      operation: operation, failure: failure, totalMilliseconds: max(0, finished - started) * 1_000,
      poolWaitMilliseconds: snapshot.poolWait, databaseMilliseconds: snapshot.database,
      schedulingDelayMilliseconds: schedulingDelay.map { $0 * 1_000 },
      remainingAuthorityMilliseconds: remaining.map { $0 * 1_000 }, retry: retry)))
    return try result.get()
  }
}
