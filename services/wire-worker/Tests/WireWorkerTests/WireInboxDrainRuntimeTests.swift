import Foundation
import Logging
import Testing
@testable import WireWorkerCore

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

  @Test("drain records accurately separated attempted and applied event counts")
  func recordsAppliedMetrics() async throws {
    let processor = FakeMetricsDrainProcessor(
      result: .init(attemptedEventCount: 7, appliedEventCount: 4)
    )
    let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let telemetry = WireInboxDrainTelemetryState(startedAt: startedAt)
    try await WireInboxDrainRuntime.run(
      processor: processor,
      state: WireWorkerHealthState(),
      logger: Logger(label: "wire-drain.test"),
      configuration: .init(idleMilliseconds: 250),
      telemetry: telemetry,
      sleeper: RecordingDrainSleeper(),
      iterationLimit: 1
    )

    let report = await telemetry.finishInterval(
      at: startedAt.addingTimeInterval(60),
      backlog: .init(actionableEventCount: 10, oldestActionableAgeSeconds: 2)
    )
    #expect(report.appliedEventCount == 4)
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

  @Test("drain-only readiness does not require a generation cycle")
  func drainOnlyReadiness() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let state = WireWorkerHealthState()
    #expect(!(await state.isDrainReady(
      at: now, maximumSuccessAge: 60, maximumOperationAge: 180
    )))

    await state.recordDrainStarted(at: now)
    #expect(await state.isDrainReady(
      at: now.addingTimeInterval(30), maximumSuccessAge: 60, maximumOperationAge: 180
    ))
    #expect(!(await state.isDrainReady(
      at: now.addingTimeInterval(181), maximumSuccessAge: 60, maximumOperationAge: 180
    )))

    await state.recordDrainSuccess(at: now)
    #expect(await state.isDrainReady(
      at: now.addingTimeInterval(59), maximumSuccessAge: 60, maximumOperationAge: 180
    ))
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

private actor FakeMetricsDrainProcessor: WireInboxProcessing {
  let result: WireInboxDrainBatchMetrics

  init(result: WireInboxDrainBatchMetrics) { self.result = result }

  func process(asOf: Date) -> Int { result.attemptedEventCount }
  func processWithMetrics(asOf: Date) -> WireInboxDrainBatchMetrics { result }
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
