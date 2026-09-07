import Foundation
import Logging
import Testing

@testable import IndexingWorkerCore

@Suite("Coordinator teardown recovery")
struct IndexingWorkerShutdownWatchdogTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("a blocked teardown expires once; repeated stop events do not reset its deadline")
  func stoppedDeadline() async {
    let state = IndexingWorkerLaneState()
    await state.record(.operationStarted, for: .wire, at: now)
    await state.record(.operationStopping(reason: .leaseLost), for: .wire, at: now)
    #expect(await state.unresponsiveLane(at: now.addingTimeInterval(29)) == nil)
    await state.record(.operationStopping(reason: .cancelled), for: .wire, at: now.addingTimeInterval(20))
    #expect(await state.unresponsiveLane(at: now.addingTimeInterval(30)) == .wire)
    await state.record(.operationStopped(reason: .cancelled), for: .wire, at: now.addingTimeInterval(31))
    #expect(await state.unresponsiveLane(at: now.addingTimeInterval(60)) == .wire)
    await state.record(.releasing, for: .wire, at: now.addingTimeInterval(61))
    #expect(await state.unresponsiveLane(at: now.addingTimeInterval(62)) == .wire)
    await state.record(.released, for: .wire, at: now.addingTimeInterval(63))
    #expect(await state.unresponsiveLane(at: now.addingTimeInterval(60)) == nil)
  }

  @Test("known contention is healthy standby but acquisition failures are not")
  func standbyRequiresContention() async {
    let state = IndexingWorkerLaneState()
    await state.record(.contended, for: .wire, at: now)
    #expect(await state.phase(for: .wire) == .standby)
    await state.record(.acquisitionFailed, for: .wire, at: now)
    #expect(await state.phase(for: .wire) == .restarting)
    #expect(await state.unresponsiveLane(at: now.addingTimeInterval(600)) == nil)
  }

  @Test("watchdog invokes process recovery for a stuck lane")
  func recoveryCallback() async throws {
    let state = IndexingWorkerLaneState()
    await state.record(.operationStopping(reason: .leaseLost), for: .wire, at: Date.distantPast)
    let (calls, continuation) = AsyncStream<Void>.makeStream()
    try await IndexingWorkerShutdownWatchdog.run(
      state: state, logger: Logger(label: "watchdog.tests"),
      terminate: { continuation.yield(()); continuation.finish() })
    var count = 0
    for await _ in calls { count += 1 }
    #expect(count == 1)
  }
}
