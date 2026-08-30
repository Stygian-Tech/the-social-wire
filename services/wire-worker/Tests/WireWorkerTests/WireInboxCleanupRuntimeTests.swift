import Foundation
import Logging
import Testing
@testable import WireWorkerCore

@Suite("The Wire terminal inbox cleanup")
struct WireInboxCleanupRuntimeTests {
  @Test("full cleanup batches continue without sleeping")
  func boundedContinuousCleanup() async throws {
    let cleaner = FakeCleaner(counts: [5_000, 3])
    let sleeper = CleanupSleeper()
    try await WireInboxCleanupRuntime.run(
      cleaner: cleaner,
      state: WireWorkerHealthState(),
      logger: Logger(label: "wire-cleanup.test"),
      batchSize: 5_000,
      idleMilliseconds: 1_000,
      sleeper: sleeper,
      iterationLimit: 2
    )
    #expect(await cleaner.calls == 2)
    #expect(await sleeper.delays == [1_000])
  }

  @Test("cleanup readiness fails closed after an error")
  func readiness() async {
    enum Failure: Error { case database }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let state = WireWorkerHealthState()
    #expect(!(await state.isCleanupReady(at: now, maximumSuccessAge: 60, maximumOperationAge: 180)))
    await state.recordCleanupSuccess(at: now, deleted: 10)
    #expect(await state.isCleanupReady(at: now.addingTimeInterval(59), maximumSuccessAge: 60, maximumOperationAge: 180))
    await state.recordCleanupFailure(Failure.database)
    #expect(!(await state.isCleanupReady(at: now, maximumSuccessAge: 60, maximumOperationAge: 180)))
  }

  @Test("cleanup failures use bounded exponential backoff and reset after recovery")
  func failureBackoff() async throws {
    let cleaner = RecoveringCleaner(results: [.failure, .failure, .success(0), .failure])
    let sleeper = CleanupSleeper()
    try await WireInboxCleanupRuntime.run(
      cleaner: cleaner,
      state: WireWorkerHealthState(),
      logger: Logger(label: "wire-cleanup.test"),
      batchSize: 5_000,
      idleMilliseconds: 1_000,
      sleeper: sleeper,
      iterationLimit: 4
    )
    #expect(await sleeper.delays == [1_000, 2_000, 1_000, 1_000])
  }
}

private actor FakeCleaner: WireInboxCleaning {
  private var counts: [Int]
  private(set) var calls = 0
  init(counts: [Int]) { self.counts = counts }
  func deleteTerminal(asOf: Date, batchSize: Int) -> Int {
    calls += 1
    return counts.removeFirst()
  }
}

private actor CleanupSleeper: WireInboxDrainSleeping {
  private(set) var delays: [Int] = []
  func sleep(milliseconds: Int) { delays.append(milliseconds) }
}

private actor RecoveringCleaner: WireInboxCleaning {
  enum Result { case failure, success(Int) }
  enum Failure: Error { case database }

  private var results: [Result]
  init(results: [Result]) { self.results = results }

  func deleteTerminal(asOf: Date, batchSize: Int) throws -> Int {
    switch results.removeFirst() {
    case .failure: throw Failure.database
    case .success(let count): return count
    }
  }
}
