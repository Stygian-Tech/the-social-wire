import Foundation
import Logging
import Testing

@testable import WireWorkerCore

@Suite("Independent repository drain", .timeLimit(.minutes(1)))
struct WireInboxRepositoryDrainRuntimeTests {
  @Test("a slow repository does not hold fast repository turns or progress telemetry")
  func independentTurns() async throws {
    let processor = RepositoryDrainFixture(queues: ["a": 2, "b": 20], blockedRepository: "a")
    let sleeper = RepositoryDrainTestSleeper()
    let telemetry = WireInboxDrainTelemetryState(startedAt: Date())
    let task = start(processor, sleeper: sleeper, telemetry: telemetry)
    defer { task.cancel() }
    try await processor.waitUntil { $0.completed.count == 20 }
    #expect(await processor.completed.allSatisfy { $0.repoDID == "b" })
    #expect(await processor.maximumLeased <= 2)
    #expect(await processor.maximumApplying <= 2)
    #expect(await processor.claimedConcurrentlyInSameRepository == false)
    try await stop(task)
    let report = await telemetry.finishInterval(
      at: Date().addingTimeInterval(60),
      backlog: .init(actionableEventCount: 2, oldestActionableAgeSeconds: 0))
    #expect(report.appliedEventCount == 20)
    #expect(await processor.admissions.filter { $0 == "b" }.count >= 10)
  }

  @Test("new repositories enter spare slots while the only active repository is blocked")
  func lateArrival() async throws {
    let processor = RepositoryDrainFixture(queues: ["a": 2], blockedRepository: "a")
    let sleeper = RepositoryDrainTestSleeper()
    let task = start(processor, sleeper: sleeper)
    defer { task.cancel() }
    try await processor.waitUntil { $0.started.contains("a") }
    try await sleeper.waitUntilSleeping()
    #expect(await processor.admissionCount == 1)
    await sleeper.tick()
    try await processor.waitUntil { $0.admissionCount == 2 }
    try await sleeper.waitUntilSleeping()
    await processor.add(repository: "b", count: 1)
    await sleeper.tick()
    try await processor.waitUntil { $0.completed.contains { $0.repoDID == "b" } }
    #expect(await processor.completed.contains { $0.repoDID == "a" } == false)
    #expect(await sleeper.maximumPending == 1)
    try await stop(task)
  }

  @Test("bounded turns admit later repositories before draining older deep repositories")
  func fairness() async throws {
    let processor = RepositoryDrainFixture(queues: ["a": 20, "b": 20, "c": 20, "d": 20, "z": 1])
    let sleeper = RepositoryDrainTestSleeper()
    let task = start(processor, sleeper: sleeper)
    defer { task.cancel() }
    try await processor.waitUntil { $0.completed.contains { $0.repoDID == "z" } }
    let admissions = await processor.admissions
    let later = try #require(admissions.firstIndex(of: "z"))
    #expect(later <= 4)
    #expect(await processor.maximumLeased <= 2)
    #expect(await processor.claimedConcurrentlyInSameRepository == false)
    try await stop(task)
  }

  @Test("retry and lost fences stop continuation while terminal events permit it")
  func outcomes() async throws {
    let processor = RepositoryDrainFixture(
      queues: ["a": 2, "b": 2, "c": 2],
      outcomes: ["a": .retry, "b": .leaseLost, "c": .terminal])
    let sleeper = RepositoryDrainTestSleeper()
    let task = start(processor, sleeper: sleeper)
    defer { task.cancel() }
    try await processor.waitUntil {
      $0.completed.contains { $0.repoDID == "c" && $0.sequence == 2 }
    }
    #expect(await processor.nextClaims["a", default: 0] == 0)
    #expect(await processor.nextClaims["b", default: 0] == 0)
    #expect(await processor.nextClaims["c", default: 0] >= 1)
    try await stop(task)
  }

  @Test("cancellation leaves the current fence recoverable and never claims the next event")
  func cancellation() async throws {
    let processor = RepositoryDrainFixture(queues: ["a": 3], blockedRepository: "a")
    let sleeper = RepositoryDrainTestSleeper()
    let state = WireWorkerHealthState()
    let task = start(processor, sleeper: sleeper, state: state)
    defer { task.cancel() }
    try await processor.waitUntil { $0.started.contains("a") }
    try await stop(task)
    #expect(await processor.completed.isEmpty)
    #expect(await processor.leased == ["a"])
    #expect(await processor.nextClaims.isEmpty)
    #expect(await state.lastDrainFailure == nil)
  }

  @Test("passive deletes and exhausted time budgets do not continue a repository turn")
  func turnBoundaries() async throws {
    for passive in [false, true] {
      let processor = RepositoryDrainFixture(queues: ["a": 3], passiveDeletes: passive)
      let sleeper = RepositoryDrainTestSleeper()
      let task = start(processor, sleeper: sleeper, maximumTurnSeconds: passive ? 100 : 0)
      defer { task.cancel() }
      try await processor.waitUntil { $0.completed.count == 3 }
      #expect(await processor.nextClaims.isEmpty)
      #expect(await processor.admissions.count == 3)
      try await stop(task)
    }
  }

  @Test("fast lane progress cannot mask an overdue active event or admission")
  func hungLaneHealth() async {
    let state = WireWorkerHealthState()
    let start = Date(timeIntervalSince1970: 1000)
    await state.recordDrainEventStarted(id: "slow", at: start)
    await state.recordDrainEventStarted(id: "fast", at: start.addingTimeInterval(180))
    await state.recordDrainEventFinished(id: "fast", at: start.addingTimeInterval(181))
    await state.recordDrainSuccess(at: start.addingTimeInterval(181))
    #expect(
      !(await state.isDrainReady(
        at: start.addingTimeInterval(181), maximumSuccessAge: 60, maximumOperationAge: 180)))
    await state.recordDrainEventStopped(id: "slow")
    #expect(
      await state.isDrainReady(
        at: start.addingTimeInterval(181), maximumSuccessAge: 60, maximumOperationAge: 180))
    await state.recordDrainStarted(at: start)
    await state.recordDrainEventFinished(id: "fast", at: start.addingTimeInterval(181))
    #expect(
      !(await state.isDrainReady(
        at: start.addingTimeInterval(181), maximumSuccessAge: 60, maximumOperationAge: 180)))
  }

  private func start(
    _ processor: RepositoryDrainFixture, sleeper: RepositoryDrainTestSleeper,
    state: WireWorkerHealthState = WireWorkerHealthState(),
    telemetry: WireInboxDrainTelemetryState? = nil, maximumTurnSeconds: TimeInterval = 100
  ) -> Task<Void, Error> {
    Task {
      try await WireInboxRepositoryDrainRuntime.run(
        processor: processor, state: state, logger: Logger(label: "repository-drain.test"),
        configuration: .init(
          maximumConcurrentEvents: 2, maximumEventsPerTurn: 2,
          maximumTurnSeconds: maximumTurnSeconds), telemetry: telemetry, sleeper: sleeper)
    }
  }

  private func stop(_ task: Task<Void, Error>) async throws {
    task.cancel()
    do {
      try await task.value
      Issue.record("drain must propagate cancellation")
    } catch is CancellationError {}
  }
}
