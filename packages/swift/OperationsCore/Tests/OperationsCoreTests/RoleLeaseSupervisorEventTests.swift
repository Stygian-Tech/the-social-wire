import Foundation
import Logging
import Testing

@testable import OperationsCore

@Suite("Role lease lifecycle events")
struct RoleLeaseSupervisorEventTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("cancellation is observable before a slow operation finishes teardown")
  func cancellationBeforeTeardown() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.url) }
    await fixture.store.useCallerRoleLeaseTestClock()
    let events = LeaseEventRecorder()
    let operationGate = LeaseOperationGate()
    let supervisor = RoleLeaseSupervisor(
      store: fixture.store, configuration: try configuration(), onEvent: events.record)
    let task = Task {
      await supervisor.run { _ in await operationGate.wait() }
    }
    await operationGate.waitUntilEntered()
    task.cancel()
    await events.wait(for: .operationStopping(reason: .cancelled))
    #expect(!events.snapshot.contains(.operationStopped(reason: .cancelled)))
    #expect(!events.snapshot.contains(.releasing))
    await operationGate.release()
    await task.value
    let values = events.snapshot.filter {
      if case .controlAttempt = $0 { return false }
      return true
    }
    #expect(values.contains(.operationStopped(reason: .cancelled)))
    #expect(values.dropLast().last == .releasing)
    // Release remains best effort: GRDB can reject the write in an already cancelled task.
    #expect(values.last == .released || values.last == .releaseFailed)
  }

  @Test("renewal failure is reported before teardown and a new owner run can start")
  func renewalFailureBeforeTeardownAndRestart() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.url) }
    await fixture.store.useCallerRoleLeaseTestClock()
    let events = LeaseEventRecorder()
    let operationGate = LeaseOperationGate()
    let renewalGate = LeaseOperationGate()
    let timing = LeaseEventTiming(now: now, renewalGate: renewalGate)
    let supervisor = RoleLeaseSupervisor(
      store: fixture.store, configuration: try configuration(), timing: timing,
      onEvent: events.record)
    let task = Task {
      await supervisor.run { _ in
        await operationGate.wait()
        while !Task.isCancelled { await Task.yield() }
      }
    }
    await operationGate.waitUntilEntered()
    await renewalGate.release()
    await events.wait(for: .operationStopping(reason: .leaseLost))
    #expect(events.snapshot.contains(.renewalFailed) || events.snapshot.contains(.authorityExpired))
    #expect(!events.snapshot.contains(.operationStopped(reason: .cancelled)))
    await operationGate.release()
    await events.waitForStarts(2)
    task.cancel()
    await task.value
    #expect(events.snapshot.filter { $0 == .operationStarted }.count >= 2)
    #expect(events.snapshot.contains(.released))
  }

  @Test("acquisition errors are distinguished from legitimate contention")
  func acquisitionFailureVersusContention() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.url) }
    await fixture.store.useCallerRoleLeaseTestClock()
    _ = try await fixture.store.acquireRoleLease(
      role: "wire-rank", ownerID: "another-owner", leaseUntil: now.addingTimeInterval(60), at: now)
    await fixture.store.useCallerRoleLeaseTestClock()
    let events = LeaseEventRecorder()
    let timing = LeaseEventTiming(now: now, renewalGate: LeaseOperationGate())
    let supervisor = RoleLeaseSupervisor(
      store: fixture.store, configuration: try configuration(), timing: timing,
      onEvent: events.record)
    let task = Task { await supervisor.run { _ in Issue.record("Contended operation must not start") } }
    await events.wait(for: .contended)
    task.cancel()
    await task.value
    #expect(!events.snapshot.contains(.acquisitionFailed))

    try await fixture.store.db.write { database in
      try database.execute(sql: "DROP TABLE operations_role_leases")
    }
    let failureEvents = LeaseEventRecorder()
    let failedSupervisor = RoleLeaseSupervisor(
      store: fixture.store, configuration: try configuration(), timing: timing,
      onEvent: failureEvents.record)
    let failedTask = Task { await failedSupervisor.run { _ in Issue.record("Failed acquisition must not start") } }
    await failureEvents.wait(for: .acquisitionFailed)
    failedTask.cancel()
    await failedTask.value
    #expect(!failureEvents.snapshot.contains(.contended))
    #expect(!failureEvents.snapshot.contains(.operationStarted))
  }

  private func configuration() throws -> RoleLeaseSupervisorConfiguration {
    try RoleLeaseSupervisorConfiguration(
      role: "wire-rank", ownerID: "replica-a", leaseDuration: 10,
      renewInterval: 3, standbyRetryInterval: 2)
  }

  private func makeFixture() throws -> (store: SQLiteOperationsStore, url: URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lease-events-\(UUID().uuidString).sqlite")
    return (try SQLiteOperationsStore(path: url.path, environment: "dev", logger: Logger(label: "lease-events.tests")), url)
  }
}

/// Locking permits synchronous cancellation-handler recording without an unstructured task.
private final class LeaseEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [RoleLeaseSupervisorEvent] = []
  private let stream: AsyncStream<RoleLeaseSupervisorEvent>
  private let continuation: AsyncStream<RoleLeaseSupervisorEvent>.Continuation
  init() { (stream, continuation) = AsyncStream.makeStream(of: RoleLeaseSupervisorEvent.self) }

  func record(_ event: RoleLeaseSupervisorEvent) {
    lock.withLock { values.append(event); continuation.yield(event) }
  }
  var snapshot: [RoleLeaseSupervisorEvent] { lock.withLock { values } }
  func wait(for event: RoleLeaseSupervisorEvent) async {
    if snapshot.contains(event) { return }
    for await value in stream where value == event { return }
  }
  func waitForStarts(_ count: Int) async {
    if snapshot.filter({ $0 == .operationStarted }).count >= count { return }
    for await _ in stream {
      if snapshot.filter({ $0 == .operationStarted }).count >= count { return }
    }
  }
}

private actor LeaseOperationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var entered = false
  private var released = false
  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered = true
      enteredContinuation?.resume()
      enteredContinuation = nil
    }
  }
  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { enteredContinuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private actor LeaseEventTiming: RoleLeaseSupervisorTiming {
  private var value: Date
  private let renewalGate: LeaseOperationGate
  private var renewed = false
  init(now: Date, renewalGate: LeaseOperationGate) { value = now; self.renewalGate = renewalGate }
  func now() -> Date { value }
  func sleep(for interval: TimeInterval) async {
    if interval == 3, !renewed {
      renewed = true
      await renewalGate.wait()
      value = value.addingTimeInterval(20)
    } else {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}
