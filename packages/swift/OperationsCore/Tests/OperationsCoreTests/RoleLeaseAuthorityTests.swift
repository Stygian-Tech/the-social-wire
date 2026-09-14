import Foundation
import Testing
@testable import OperationsCore

@Suite("Confirmed role authority")
struct RoleLeaseAuthorityTests {
  @Test("renewal cadence is measured from query start, not its completion")
  func renewalCadence() async throws {
    let clock = ControlledLeaseClock()
    let store = ControlledLeaseStore(clock: clock, queryDuration: 3)
    let events = ControlledLeaseEvents()
    let supervisor = try makeSupervisor(store, clock, events)
    let task = Task { await supervisor.run { _ in try await Task.sleep(for: .seconds(1_000)) } }
    await events.wait { $0 == .operationStarted }
    await clock.waitForSleeper(at: 10)
    clock.advance(by: 10)
    await events.wait { if case .controlAttempt(let value) = $0 { return value.operation == .renew }; return false }
    await clock.waitForSleeper(at: 20)
    clock.advance(by: 7)
    await events.wait { if case .controlAttempt(let value) = $0 { return value.operation == .renew && value.totalMilliseconds == 3_000 && events.renewals.count == 2 }; return false }
    task.cancel()
    await task.value
    #expect(await store.starts == [10, 20])
    #expect(events.renewals.allSatisfy { $0.schedulingDelayMilliseconds == 0 })
  }

  @Test("two transient retries preserve the same owner and only a reply extends authority")
  func transientRetries() async throws {
    let clock = ControlledLeaseClock()
    let store = ControlledLeaseStore(clock: clock, failures: [.connectionUnavailable, .lockTimeout])
    let events = ControlledLeaseEvents()
    let task = Task { await (try makeSupervisor(store, clock, events)).run { _ in try await Task.sleep(for: .seconds(1_000)) } }
    await events.wait { $0 == .operationStarted }
    await clock.waitForSleeper(at: 10)
    clock.advance(by: 10)
    await clock.waitForSleeper(at: 11)
    clock.advance(by: 1)
    await clock.waitForSleeper(at: 12)
    clock.advance(by: 1)
    await events.wait { if case .controlAttempt(let value) = $0 { return value.operation == .renew && value.failure == nil }; return false }
    task.cancel()
    _ = try await task.value
    #expect(await store.starts == [10, 11, 12])
    #expect(events.renewals.map(\.retry) == [0, 1, 2])
    #expect(!events.values.contains(.renewalFailed))
    #expect(events.values.filter { $0 == .operationStarted }.count == 1)
  }

  @Test("transient retries are capped and cannot consume the authority margin", arguments: [0.0, 12.0])
  func retryBounds(queryDuration: Double) async throws {
    let clock = ControlledLeaseClock()
    let store = ControlledLeaseStore(clock: clock,
      failures: [.connectionUnavailable, .connectionUnavailable, .connectionUnavailable], queryDuration: queryDuration)
    let events = ControlledLeaseEvents()
    let task = Task { await (try makeSupervisor(store, clock, events)).run { _ in try await Task.sleep(for: .seconds(1_000)) } }
    await events.wait { $0 == .operationStarted }
    await clock.waitForSleeper(at: 10)
    clock.advance(by: 10)
    if queryDuration == 0 {
      await clock.waitForSleeper(at: 11)
      clock.advance(by: 1)
      await clock.waitForSleeper(at: 12)
      clock.advance(by: 1)
    }
    await events.wait { $0 == .renewalFailed }
    task.cancel()
    _ = try await task.value
    #expect(events.renewals.count == (queryDuration == 0 ? 3 : 1))
  }

  @Test("an overslept retry cannot start without a full remaining attempt budget")
  func retryOversleep() async throws {
    let clock = ControlledLeaseClock()
    let store = ControlledLeaseStore(clock: clock, failures: [.connectionUnavailable])
    let events = ControlledLeaseEvents()
    let task = Task { await (try makeSupervisor(store, clock, events)).run { _ in try await Task.sleep(for: .seconds(1_000)) } }
    await events.wait { $0 == .operationStarted }
    await clock.waitForSleeper(at: 10)
    clock.advance(by: 10)
    await clock.waitForSleeper(at: 11)
    clock.advance(by: 13)
    await events.wait { $0 == .renewalFailed }
    task.cancel()
    _ = try await task.value
    #expect(await store.starts == [10])
  }

  @Test("watchdog stops work while a renewal reply is withheld")
  func watchdogDuringHungRenewal() async throws {
    let clock = ControlledLeaseClock()
    let store = ControlledLeaseStore(clock: clock, holdRenewal: true)
    let events = ControlledLeaseEvents()
    let task = Task { await (try makeSupervisor(store, clock, events)).run { _ in try await Task.sleep(for: .seconds(1_000)) } }
    await events.wait { $0 == .operationStarted }
    await clock.waitForSleeper(at: 10)
    clock.advance(by: 10)
    await store.waitUntilRenewing()
    clock.advance(by: 15)
    await events.wait { $0 == .authorityExpired }
    await events.wait { $0 == .operationStopped(reason: .cancelled) }
    #expect(!events.values.contains(.releasing))
    // A late success cannot revive expired authority, even with a nominal fresh grant.
    await store.releaseRenewal()
    await events.wait { $0 == .released }
    task.cancel()
    _ = try await task.value
    #expect(events.values.filter { $0 == .operationStarted }.count == 1)
  }

  @Test("delayed watchdog sleep entry retains the original authority deadline")
  func delayedWatchdogSleepEntry() async throws {
    let clock = ControlledLeaseClock()
    let timing = DelayedWatchdogLeaseClock(clock: clock)
    let store = ControlledLeaseStore(clock: clock, holdRenewal: true)
    let events = ControlledLeaseEvents()
    let task = Task { await (try makeSupervisor(store, timing, events)).run { _ in try await Task.sleep(for: .seconds(1_000)) } }
    await events.wait { $0 == .operationStarted }
    await clock.waitForSleeper(at: 10)
    await timing.entered.wait()
    clock.advance(by: 10)
    await store.waitUntilRenewing()
    clock.advance(by: 15)
    // The sleep implementation only starts now. Relative sleep would incorrectly
    // wait another 25 seconds, despite authority already having expired.
    await timing.resume.open()
    await events.wait { $0 == .authorityExpired }
    await events.wait { $0 == .operationStopped(reason: .cancelled) }
    task.cancel()
    await store.releaseRenewal()
    _ = try await task.value
    #expect(events.values.filter { $0 == .operationStarted }.count == 1)
  }

  @Test("fencing conflict immediately tears down and restarts with new authority")
  func conflictRestarts() async throws {
    let clock = ControlledLeaseClock()
    let store = ControlledLeaseStore(clock: clock, failures: [.leaseConflict])
    let events = ControlledLeaseEvents()
    let task = Task { await (try makeSupervisor(store, clock, events)).run { _ in try await Task.sleep(for: .seconds(1_000)) } }
    await events.wait { $0 == .operationStarted }
    await clock.waitForSleeper(at: 10)
    clock.advance(by: 10)
    await events.wait { $0 == .renewalFailed }
    await clock.waitForSleeper(at: 15)
    clock.advance(by: 5)
    await events.wait { $0 == .acquired(fencingToken: 2) }
    task.cancel()
    _ = try await task.value
    #expect(events.renewals.count == 1)
    #expect(events.renewals.first?.failure == .leaseConflict)
    #expect(events.values.contains(.operationStopped(reason: .cancelled)))
  }

  @Test("authority expiration and the retry safety margin are strict")
  func deadlineBoundary() async throws {
    let authority = RoleLeaseAuthorityDeadline(deadline: 25)
    try await authority.check(at: 24.999)
    await #expect(throws: RoleLeaseFailure.authorityExpired) { try await authority.check(at: 25) }
    await #expect(throws: RoleLeaseFailure.authorityExpired) {
      try await authority.confirm(deadline: 50, at: 25)
    }
    #expect(await authority.remaining(at: 26) == 0)
    #expect(!RoleLeaseFailure.leaseConflict.isTransient)
    #expect(!RoleLeaseFailure.cancelled.isTransient)
    #expect(!RoleLeaseFailure.unknown.isTransient)
  }

  @Test("unknown errors expose no sensitive text")
  func safeClassification() {
    struct SensitiveError: Error, CustomStringConvertible { var description: String { "SELECT secret" } }
    #expect(RoleLeaseFailure.classify(SensitiveError()) == .unknown)
    #expect(RoleLeaseFailure.classify(OperationsStoreError.leaseConflict) == .leaseConflict)
    #expect(RoleLeaseFailure.classify(CancellationError()) == .cancelled)
  }

  private func makeSupervisor(
    _ store: ControlledLeaseStore, _ clock: any RoleLeaseSupervisorTiming, _ events: ControlledLeaseEvents
  ) throws -> RoleLeaseSupervisor {
    RoleLeaseSupervisor(store: store, configuration: try RoleLeaseSupervisorConfiguration(
      role: "wire", ownerID: "replica", leaseDuration: 30, renewInterval: 10, standbyRetryInterval: 5),
      timing: clock, onEvent: events.record)
  }
}

private final class ControlledLeaseClock: RoleLeaseSupervisorTiming, @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval = 0
  private var sleepers: [UUID: (TimeInterval, AsyncStream<Void>.Continuation)] = [:]
  var instant: TimeInterval { lock.withLock { value } }
  func now() async -> Date { Date(timeIntervalSince1970: instant) }
  func monotonicNow() async -> TimeInterval { instant }
  func sleep(for interval: TimeInterval) async { await sleep(until: instant + interval) }
  func sleep(until deadline: TimeInterval) async {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    lock.withLock {
      if value >= deadline { continuation.finish() }
      else { sleepers[id] = (deadline, continuation) }
    }
    defer { _ = lock.withLock { sleepers.removeValue(forKey: id) }; continuation.finish() }
    for await _ in stream { if instant >= deadline { return } }
  }
  func advance(by interval: TimeInterval) {
    lock.withLock {
      value += interval
      for (_, continuation) in sleepers.values { continuation.yield(()) }
    }
  }
  func waitForSleeper(at deadline: TimeInterval) async {
    while !lock.withLock({ sleepers.values.contains { abs($0.0 - deadline) < 0.0001 } }) {
      await Task.yield()
    }
  }
}

private actor ControlledLeaseStore: RoleLeaseStoring {
  let clock: ControlledLeaseClock
  var failures: [RoleLeaseFailure]
  let queryDuration: TimeInterval
  let holdRenewal: Bool
  var starts: [TimeInterval] = []
  private var pending: CheckedContinuation<Void, Never>?
  private var renewEntered = false
  private var token: Int64 = 0
  init(clock: ControlledLeaseClock, failures: [RoleLeaseFailure] = [], queryDuration: TimeInterval = 0, holdRenewal: Bool = false) {
    self.clock = clock; self.failures = failures; self.queryDuration = queryDuration; self.holdRenewal = holdRenewal
  }
  func acquireRoleLease(role: String, ownerID: String, leaseUntil: Date, at: Date) async throws -> FencedRoleLease? {
    token += 1
    return grant(role: role, owner: ownerID, duration: leaseUntil.timeIntervalSince(at))
  }
  func renewRoleLease(role: String, ownerID: String, fencingToken: Int64, leaseUntil: Date, at: Date) async throws -> FencedRoleLease {
    starts.append(clock.instant)
    if holdRenewal { await withCheckedContinuation { pending = $0; renewEntered = true } }
    clock.advance(by: queryDuration)
    if !failures.isEmpty { throw failures.removeFirst() }
    return grant(role: role, owner: ownerID, duration: leaseUntil.timeIntervalSince(at))
  }
  func releaseRoleLease(role: String, ownerID: String, fencingToken: Int64, at: Date) async throws {}
  func withRoleLeaseFence(role: String, ownerID: String, fencingToken: Int64, at: Date, operation: @Sendable @escaping () async throws -> Void) async throws { try await operation() }
  func waitUntilRenewing() async { while !renewEntered { await Task.yield() } }
  func releaseRenewal() { pending?.resume(); pending = nil }
  private func grant(role: String, owner: String, duration: TimeInterval) -> FencedRoleLease {
    let now = Date(timeIntervalSince1970: clock.instant)
    return FencedRoleLease(environment: "test", role: role, ownerID: owner, fencingToken: token,
      acquiredAt: now, expiresAt: now.addingTimeInterval(duration), updatedAt: now)
  }
}

private final class ControlledLeaseEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RoleLeaseSupervisorEvent] = []
  private let stream: AsyncStream<RoleLeaseSupervisorEvent>
  private let continuation: AsyncStream<RoleLeaseSupervisorEvent>.Continuation
  init() { (stream, continuation) = AsyncStream.makeStream(of: RoleLeaseSupervisorEvent.self) }
  var values: [RoleLeaseSupervisorEvent] { lock.withLock { storage } }
  var renewals: [RoleLeaseControlObservation] {
    values.compactMap { if case .controlAttempt(let value) = $0, value.operation == .renew { return value }; return nil }
  }
  func record(_ event: RoleLeaseSupervisorEvent) { lock.withLock { storage.append(event); continuation.yield(event) } }
  func wait(_ predicate: (RoleLeaseSupervisorEvent) -> Bool) async {
    if values.contains(where: predicate) { return }
    for await event in stream where predicate(event) { return }
  }
}

private struct DelayedWatchdogLeaseClock: RoleLeaseSupervisorTiming {
  let clock: ControlledLeaseClock
  let entered = ControlledLeaseGate()
  let resume = ControlledLeaseGate()
  func now() async -> Date { await clock.now() }
  func monotonicNow() async -> TimeInterval { clock.instant }
  func sleep(for interval: TimeInterval) async { await clock.sleep(for: interval) }
  func sleep(until deadline: TimeInterval) async {
    if deadline == 25 { await entered.open(); await resume.wait() }
    await clock.sleep(until: deadline)
  }
}

private actor ControlledLeaseGate {
  private var opened = false
  private var continuations: [CheckedContinuation<Void, Never>] = []
  func wait() async { if !opened { await withCheckedContinuation { continuations.append($0) } } }
  func open() { opened = true; let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
}
