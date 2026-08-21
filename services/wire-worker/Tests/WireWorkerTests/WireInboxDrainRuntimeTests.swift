import Foundation
import Logging
import Testing
@testable import WireWorker

@Suite("The Wire continuous inbox drain")
struct WireInboxDrainRuntimeTests {
  private enum TestError: Error { case unavailable }

  @Test("full batches drain continuously and only an empty batch idles")
  func continuousDrain() async throws {
    let processor = FakeDrainProcessor(outcomes: [.success(1_000), .success(1_000), .success(0), .success(4)])
    let sleeper = RecordingDrainSleeper()
    try await WireInboxDrainRuntime.run(
      processor: processor,
      state: WireWorkerHealthState(),
      logger: Logger(label: "wire-drain.test"),
      configuration: .init(idleMilliseconds: 250),
      sleeper: sleeper,
      iterationLimit: 4
    )

    #expect(await processor.callCount == 4)
    #expect(await sleeper.delays == [250])
  }

  @Test("errors back off exponentially and a success resets the drain")
  func errorBackoff() async throws {
    let processor = FakeDrainProcessor(outcomes: [
      .failure(TestError.unavailable), .failure(TestError.unavailable), .success(0),
    ])
    let sleeper = RecordingDrainSleeper()
    let state = WireWorkerHealthState()
    try await WireInboxDrainRuntime.run(
      processor: processor,
      state: state,
      logger: Logger(label: "wire-drain.test"),
      configuration: .init(
        idleMilliseconds: 250,
        initialErrorBackoffMilliseconds: 1_000,
        maximumErrorBackoffMilliseconds: 30_000
      ),
      sleeper: sleeper,
      iterationLimit: 3
    )

    #expect(await sleeper.delays == [1_000, 2_000, 250])
    #expect(await state.lastDrainFailure == nil)
    #expect(await state.lastSuccessfulDrainAt != nil)
  }

  @Test("readiness requires a recent generation and a healthy active or recent drain")
  func readiness() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let state = WireWorkerHealthState()
    #expect(!(await ready(state, at: now)))

    await state.recordGenerationSuccess(at: now)
    await state.recordDrainStarted(at: now)
    #expect(await ready(state, at: now.addingTimeInterval(30)))
    #expect(!(await ready(state, at: now.addingTimeInterval(181))))

    await state.recordDrainFailure(TestError.unavailable)
    #expect(!(await ready(state, at: now)))
    await state.recordDrainSuccess(at: now)
    #expect(await ready(state, at: now.addingTimeInterval(59)))
    #expect(!(await ready(state, at: now.addingTimeInterval(61))))
  }

  private func ready(_ state: WireWorkerHealthState, at date: Date) async -> Bool {
    await state.isReady(
      at: date,
      maximumCycleAge: 600,
      maximumDrainSuccessAge: 60,
      maximumDrainOperationAge: 180
    )
  }
}

private actor FakeDrainProcessor: WireInboxProcessing {
  enum Outcome: Sendable {
    case success(Int)
    case failure(any Error & Sendable)
  }

  private var outcomes: [Outcome]
  private(set) var callCount = 0

  init(outcomes: [Outcome]) { self.outcomes = outcomes }

  func process(asOf: Date) throws -> Int {
    callCount += 1
    guard !outcomes.isEmpty else { return 0 }
    switch outcomes.removeFirst() {
    case .success(let count): return count
    case .failure(let error): throw error
    }
  }
}

private actor RecordingDrainSleeper: WireInboxDrainSleeping {
  private(set) var delays: [Int] = []
  func sleep(milliseconds: Int) { delays.append(milliseconds) }
}
