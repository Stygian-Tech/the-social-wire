import Foundation

public protocol RoleLeaseSupervisorTiming: Sendable {
  func now() async -> Date
  func sleep(for interval: TimeInterval) async
}

public struct SystemRoleLeaseSupervisorTiming: RoleLeaseSupervisorTiming {
  public init() {}

  public func now() async -> Date { Date() }

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
      leaseDuration.isFinite, leaseDuration > 0,
      renewInterval.isFinite, renewInterval > 0, renewInterval < leaseDuration,
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

  private let store: any OperationsStore

  init(lease: FencedRoleLease, store: any OperationsStore) {
    environment = lease.environment
    role = lease.role
    ownerID = lease.ownerID
    fencingToken = lease.fencingToken
    self.store = store
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
  private let store: any OperationsStore
  private let configuration: RoleLeaseSupervisorConfiguration
  private let timing: any RoleLeaseSupervisorTiming
  private let onEvent: @Sendable (RoleLeaseSupervisorEvent) -> Void

  /// `onEvent` is synchronous and may run concurrently from renewal and operation tasks.
  /// Keep it nonblocking; an AsyncStream continuation can forward ordered signals to an actor.
  public init(
    store: any OperationsStore,
    configuration: RoleLeaseSupervisorConfiguration,
    timing: any RoleLeaseSupervisorTiming = SystemRoleLeaseSupervisorTiming(),
    onEvent: @escaping @Sendable (RoleLeaseSupervisorEvent) -> Void = { _ in }
  ) {
    self.store = store
    self.configuration = configuration
    self.timing = timing
    self.onEvent = onEvent
  }

  /// Repeatedly acquires the configured role and runs `operation` only while this owner holds it.
  /// Store failures, contention, lost leases, and operation exits all return to bounded standby.
  /// Cancellation stops the active operation and releases the lease best-effort.
  public func run(
    operation: @Sendable @escaping (RoleLeaseOwnership) async throws -> Void
  ) async {
    while !Task.isCancelled {
      do {
        onEvent(.acquiring)
        let acquiredAt = await timing.now()
        if let lease = try await store.acquireRoleLease(
          role: configuration.role,
          ownerID: configuration.ownerID,
          leaseUntil: acquiredAt.addingTimeInterval(configuration.leaseDuration),
          at: acquiredAt
        ) {
          onEvent(.acquired(fencingToken: lease.fencingToken))
          await runOwned(lease: lease, operation: operation)
        } else {
          onEvent(.contended)
        }
      } catch {
        onEvent(.acquisitionFailed)
        // Fail closed: the operation never starts when durable ownership is unavailable.
      }
      guard !Task.isCancelled else { return }
      await timing.sleep(for: configuration.standbyRetryInterval)
    }
  }

  private func runOwned(
    lease: FencedRoleLease,
    operation: @Sendable @escaping (RoleLeaseOwnership) async throws -> Void
  ) async {
    let ownership = RoleLeaseOwnership(lease: lease, store: store)
    do {
      let validationTime = await timing.now()
      do {
        try await ownership.withFence(at: validationTime) {}
      } catch {
        onEvent(.validationFailed)
        throw error
      }
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await withTaskCancellationHandler {
            do {
              try Task.checkCancellation()
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
            // This runs synchronously when cancellation begins, before structured teardown
            // waits for the operation's children. Observers must not block this callback.
            onEvent(.operationStopping(reason: .cancelled))
          }
        }
        group.addTask {
          while !Task.isCancelled {
            await timing.sleep(for: configuration.renewInterval)
            try Task.checkCancellation()
            let renewedAt = await timing.now()
            do {
              _ = try await store.renewRoleLease(
                role: configuration.role,
                ownerID: configuration.ownerID,
                fencingToken: lease.fencingToken,
                leaseUntil: renewedAt.addingTimeInterval(configuration.leaseDuration),
                at: renewedAt
              )
            } catch {
              if !Task.isCancelled {
                onEvent(.renewalFailed)
                onEvent(.operationStopping(reason: .leaseLost))
              }
              throw error
            }
          }
        }
        _ = try await group.next()
        group.cancelAll()
      }
    } catch {
      // A lost lease or operation failure cancels its sibling and returns to standby.
    }
    let releasedAt = await timing.now()
    onEvent(.releasing)
    do {
      try await store.releaseRoleLease(
        role: configuration.role,
        ownerID: configuration.ownerID,
        fencingToken: lease.fencingToken,
        at: releasedAt
      )
      onEvent(.released)
    } catch {
      onEvent(.releaseFailed)
    }
  }
}
