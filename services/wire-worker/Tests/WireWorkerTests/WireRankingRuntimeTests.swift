import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Wire ranking runtime ownership replacement")
struct WireRankingRuntimeTests {
  @Test("fresh hosts share a full-cycle cadence without catch-up bursts")
  func recreatedHosts() async throws {
    let scheduler = WireRankingScheduler()
    let clock = RankingRuntimeClock()
    let sleeper = RankingRuntimeSleeper(clock: clock)
    for _ in 0..<3 {
      try await WireWorkerRuntime.runScheduled(
        intervalSeconds: 600, scheduler: scheduler, sleeper: sleeper,
        monotonicNow: { await clock.now() }, iterationLimit: 1,
        operation: { await clock.advance(seconds: 40) })
    }
    #expect(await sleeper.delays == [560_000, 560_000])
  }

  @Test("partial cycle failure retries after sixty seconds across replacement hosts")
  func partialCycleFailure() async throws {
    let scheduler = WireRankingScheduler()
    let clock = RankingRuntimeClock()
    let sleeper = RankingRuntimeSleeper(clock: clock)
    try await WireWorkerRuntime.runScheduled(
      intervalSeconds: 600, scheduler: scheduler, sleeper: sleeper,
      monotonicNow: { await clock.now() }, iterationLimit: 1,
      operation: {
        // Models a primary publication followed by failure in a later language.
        await clock.advance(seconds: 40)
        throw RankingRuntimeFailure()
      })
    try await WireWorkerRuntime.runScheduled(
      intervalSeconds: 600, scheduler: scheduler, sleeper: sleeper,
      monotonicNow: { await clock.now() }, iterationLimit: 1, operation: {})
    #expect(await sleeper.delays == [60_000])
  }

  @Test("canceled work holds its token through teardown then retains retry backoff")
  func cancellationDuringWork() async throws {
    let scheduler = WireRankingScheduler()
    let clock = RankingRuntimeClock()
    let started = RankingRuntimeGate()
    let teardown = RankingRuntimeGate()
    let task = Task {
      try await WireWorkerRuntime.runScheduled(
        intervalSeconds: 600, scheduler: scheduler,
        monotonicNow: { await clock.now() }, iterationLimit: 1,
        operation: {
          await started.open()
          await teardown.wait()
        })
    }
    await started.wait()
    task.cancel()
    #expect(await scheduler.reserve(at: clock.now()) == .wait(milliseconds: 1_000))
    await teardown.open()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await scheduler.reserve(at: clock.now()) == .wait(milliseconds: 60_000))
    let sleeper = RankingRuntimeSleeper(clock: clock)
    try await WireWorkerRuntime.runScheduled(
      intervalSeconds: 600, scheduler: scheduler, sleeper: sleeper,
      monotonicNow: { await clock.now() }, iterationLimit: 1, operation: {})
    #expect(await sleeper.delays == [60_000])
  }

  @Test("failure handling finishes before the active token is released")
  func failureTeardown() async throws {
    let scheduler = WireRankingScheduler()
    let clock = RankingRuntimeClock()
    let entered = RankingRuntimeGate()
    let teardown = RankingRuntimeGate()
    let task = Task {
      try await WireWorkerRuntime.runScheduled(
        intervalSeconds: 600, scheduler: scheduler,
        monotonicNow: { await clock.now() }, iterationLimit: 1,
        operation: { throw RankingRuntimeFailure() },
        onFailure: { _ in
          await entered.open()
          await teardown.wait()
        })
    }
    await entered.wait()
    #expect(await scheduler.reserve(at: clock.now()) == .wait(milliseconds: 1_000))
    await teardown.open()
    try await task.value
    #expect(await scheduler.reserve(at: clock.now()) == .wait(milliseconds: 60_000))
  }

  @Test("cancellation while acquiring a reservation releases it into retry backoff")
  func cancellationDuringReservation() async throws {
    let scheduler = WireRankingScheduler()
    let clock = RankingRuntimeClock()
    let entered = RankingRuntimeGate()
    let resume = RankingRuntimeGate()
    let task = Task {
      try await WireWorkerRuntime.runScheduled(
        intervalSeconds: 600, scheduler: scheduler,
        monotonicNow: {
          await entered.open()
          await resume.wait()
          return await clock.now()
        }, iterationLimit: 1,
        operation: { Issue.record("Canceled reservation started ranking") })
    }
    await entered.wait()
    task.cancel()
    await resume.open()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await scheduler.reserve(at: clock.now()) == .wait(milliseconds: 60_000))
  }

  @Test("cancellation during cadence sleep preserves the existing deadline")
  func cancellationDuringWait() async throws {
    let scheduler = WireRankingScheduler()
    let clock = RankingRuntimeClock()
    try await WireWorkerRuntime.runScheduled(
      intervalSeconds: 600, scheduler: scheduler,
      monotonicNow: { await clock.now() }, iterationLimit: 1, operation: {})
    await clock.advance(seconds: 20)
    await #expect(throws: CancellationError.self) {
      try await WireWorkerRuntime.runScheduled(
        intervalSeconds: 600, scheduler: scheduler, sleeper: RankingRuntimeCanceledSleeper(),
        monotonicNow: { await clock.now() }, iterationLimit: 1,
        operation: { Issue.record("Cycle started before its retained deadline") })
    }
    #expect(await scheduler.reserve(at: clock.now()) == .wait(milliseconds: 580_000))
  }
}

private actor RankingRuntimeClock {
  private var instant = ContinuousClock.now
  func now() -> ContinuousClock.Instant { instant }
  func advance(seconds: Double) { instant = instant.advanced(by: .seconds(seconds)) }
}

private actor RankingRuntimeSleeper: WireInboxDrainSleeping {
  let clock: RankingRuntimeClock
  var delays: [Int] = []
  init(clock: RankingRuntimeClock) { self.clock = clock }
  func sleep(milliseconds: Int) async {
    delays.append(milliseconds)
    await clock.advance(seconds: Double(milliseconds) / 1_000)
  }
}

private actor RankingRuntimeGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !opened else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    opened = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private struct RankingRuntimeFailure: Error {}

private struct RankingRuntimeCanceledSleeper: WireInboxDrainSleeping {
  func sleep(milliseconds: Int) async throws { throw CancellationError() }
}
