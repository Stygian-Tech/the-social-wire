import Foundation
import Logging
import Testing

@testable import OperationsCore

@Suite("Role lease supervisor")
struct RoleLeaseSupervisorTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("configuration rejects unsafe renewal and retry intervals")
  func invalidConfiguration() {
    #expect(throws: RoleLeaseSupervisorError.invalidConfiguration) {
      _ = try RoleLeaseSupervisorConfiguration(
        role: "wire-rank", ownerID: "replica-a",
        leaseDuration: 10, renewInterval: 10, standbyRetryInterval: 1
      )
    }
    #expect(throws: RoleLeaseSupervisorError.invalidConfiguration) {
      _ = try RoleLeaseSupervisorConfiguration(
        role: "wire-rank", ownerID: "replica-a",
        leaseDuration: 10, renewInterval: 3, standbyRetryInterval: 0
      )
    }
  }

  @Test("lost ownership cancels the operation and reruns it with a new fence")
  func lostOwnershipRerunsOperation() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-role-supervisor-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path,
      environment: "dev",
      logger: Logger(label: "operations.role-supervisor.test")
    )
    let timing = OversleepRoleLeaseTiming(now: now, elapsedPerSleep: 20)
    let configuration = try RoleLeaseSupervisorConfiguration(
      role: "wire-rank",
      ownerID: "replica-a",
      leaseDuration: 10,
      renewInterval: 3,
      standbyRetryInterval: 2
    )
    let supervisor = RoleLeaseSupervisor(
      store: store, configuration: configuration, timing: timing
    )
    let (ownerships, continuation) = AsyncStream.makeStream(of: RoleLeaseOwnership.self)
    let task = Task {
      await supervisor.run { ownership in
        try await ownership.withFence(at: await timing.now()) {
          continuation.yield(ownership)
        }
        while !Task.isCancelled { await Task.yield() }
      }
    }

    var iterator = ownerships.makeAsyncIterator()
    let first = try #require(await iterator.next())
    let successor = try #require(await iterator.next())
    task.cancel()
    await task.value
    continuation.finish()

    #expect(first.environment == "dev")
    #expect(first.role == configuration.role)
    #expect(first.ownerID == configuration.ownerID)
    #expect(first.fencingToken == 1)
    #expect(successor.fencingToken == first.fencingToken + 1)
    #expect(await timing.requestedIntervals().contains(configuration.renewInterval))
    #expect(await timing.requestedIntervals().contains(configuration.standbyRetryInterval))
  }
}

private actor OversleepRoleLeaseTiming: RoleLeaseSupervisorTiming {
  private var current: Date
  private let elapsedPerSleep: TimeInterval
  private var intervals: [TimeInterval] = []

  init(now: Date, elapsedPerSleep: TimeInterval) {
    current = now
    self.elapsedPerSleep = elapsedPerSleep
  }

  func now() async -> Date { current }

  func sleep(for interval: TimeInterval) async {
    intervals.append(interval)
    current = current.addingTimeInterval(elapsedPerSleep)
    await Task.yield()
  }

  func requestedIntervals() -> [TimeInterval] { intervals }
}
