import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Wire ranking readiness across host recreation")
struct WireRankingReadinessTests {
  @Test("completed-cycle evidence survives host recreation without refreshing telemetry")
  func recreatedHost() async {
    let scheduler = WireRankingScheduler()
    let start = ContinuousClock.now
    #expect(await scheduler.isGenerationReady(at: start, maximumCycleAge: .seconds(1_200)) == false)
    guard case .run(let token) = await scheduler.reserve(at: start) else {
      Issue.record("Expected an initial ranking attempt")
      return
    }
    #expect(await scheduler.isGenerationReady(at: start, maximumCycleAge: .seconds(1_200)) == false)
    await scheduler.succeeded(token, at: start.advanced(by: .seconds(40)), intervalSeconds: 600)

    let freshState = WireWorkerHealthState()
    let recreatedAt = start.advanced(by: .seconds(60))
    #expect(await scheduler.reserve(at: recreatedAt) == .wait(milliseconds: 540_000))
    #expect(await scheduler.isGenerationReady(at: recreatedAt, maximumCycleAge: .seconds(1_200)))
    #expect(await freshState.lastSuccessfulCycleAt == nil)
    #expect(await freshState.lastGenerationDurationMilliseconds == nil)
    #expect(await freshState.lastGenerationFailure == nil)
  }

  @Test("readiness expires from original attempt start, not completion or host recreation")
  func evidenceAge() async {
    let scheduler = WireRankingScheduler()
    let start = ContinuousClock.now
    guard case .run(let token) = await scheduler.reserve(at: start) else {
      Issue.record("Expected a ranking reservation at its due time")
      return
    }
    await scheduler.succeeded(token, at: start.advanced(by: .seconds(400)), intervalSeconds: 600)
    #expect(await scheduler.isGenerationReady(at: start.advanced(by: .seconds(1_200)), maximumCycleAge: .seconds(1_200)))
    #expect(await scheduler.isGenerationReady(at: start.advanced(by: .milliseconds(1_200_001)), maximumCycleAge: .seconds(1_200)) == false)
    #expect(await scheduler.isGenerationReady(at: start.advanced(by: .seconds(-1)), maximumCycleAge: .seconds(1_200)) == false)

    // Reserving another cycle never makes old evidence fresh again.
    guard case .run = await scheduler.reserve(at: start.advanced(by: .seconds(1_300))) else {
      Issue.record("Expected a ranking reservation at its due time")
      return
    }
    #expect(await scheduler.isGenerationReady(at: start.advanced(by: .seconds(1_300)), maximumCycleAge: .seconds(1_200)) == false)
  }

  @Test("matching failure clears readiness and stale tokens cannot erase new evidence")
  func failedCycle() async {
    let scheduler = WireRankingScheduler()
    let start = ContinuousClock.now
    guard case .run(let first) = await scheduler.reserve(at: start) else {
      Issue.record("Expected a ranking reservation at its due time")
      return
    }
    await scheduler.succeeded(first, at: start, intervalSeconds: 600)
    let nextStart = start.advanced(by: .seconds(600))
    guard case .run(let second) = await scheduler.reserve(at: nextStart) else {
      Issue.record("Expected a ranking reservation at its due time")
      return
    }
    #expect(await scheduler.isGenerationReady(at: nextStart, maximumCycleAge: .seconds(1_200)))
    await scheduler.failed(second, at: nextStart)
    #expect(await scheduler.isGenerationReady(at: nextStart, maximumCycleAge: .seconds(1_200)) == false)
    #expect(await scheduler.reserve(at: nextStart) == .wait(milliseconds: 60_000))

    let retryAt = nextStart.advanced(by: .seconds(60))
    guard case .run(let retry) = await scheduler.reserve(at: retryAt) else {
      Issue.record("Expected a ranking reservation at its due time")
      return
    }
    await scheduler.succeeded(retry, at: retryAt, intervalSeconds: 600)
    await scheduler.failed(second, at: retryAt)
    #expect(await scheduler.isGenerationReady(at: retryAt, maximumCycleAge: .seconds(1_200)))
  }
}
