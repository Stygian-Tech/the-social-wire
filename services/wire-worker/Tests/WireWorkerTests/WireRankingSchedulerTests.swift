import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Wire ranking scheduling across ownership changes")
struct WireRankingSchedulerTests {
  @Test("complete cycles retain processing-aware cadence across replacement hosts")
  func successfulCadence() async {
    let scheduler = WireRankingScheduler()
    let start = ContinuousClock.now
    guard case .run(let token) = await scheduler.reserve(at: start) else {
      Issue.record("First ranking cycle should run immediately")
      return
    }
    await scheduler.succeeded(token, at: start.advanced(by: .seconds(40)), intervalSeconds: 600)
    #expect(await scheduler.reserve(at: start.advanced(by: .seconds(70))) == .wait(milliseconds: 530_000))
    guard case .run(let replacement) = await scheduler.reserve(at: start.advanced(by: .seconds(600))) else {
      Issue.record("Replacement host should run at the retained deadline")
      return
    }
    // A slow attempt allows one next cycle, whose start establishes a fresh cadence.
    let later = start.advanced(by: .seconds(1_900))
    await scheduler.succeeded(replacement, at: later, intervalSeconds: 600)
    guard case .run(let next) = await scheduler.reserve(at: later) else {
      Issue.record("Slow cycles should not add a post-processing interval")
      return
    }
    await scheduler.succeeded(next, at: later.advanced(by: .seconds(10)), intervalSeconds: 600)
    #expect(await scheduler.reserve(at: later.advanced(by: .seconds(10))) == .wait(milliseconds: 590_000))
  }

  @Test("hung work retains its token and stale completions cannot release another attempt")
  func noOverlap() async {
    let scheduler = WireRankingScheduler()
    let start = ContinuousClock.now
    guard case .run(let first) = await scheduler.reserve(at: start) else { return }
    #expect(await scheduler.reserve(at: start.advanced(by: .seconds(10_000))) == .wait(milliseconds: 1_000))
    await scheduler.failed(first, at: start)
    #expect(await scheduler.reserve(at: start) == .wait(milliseconds: 60_000))
    let due = start.advanced(by: .seconds(60))
    guard case .run(let second) = await scheduler.reserve(at: due) else { return }
    await scheduler.succeeded(first, at: due, intervalSeconds: 600)
    await scheduler.failed(first, at: due)
    #expect(await scheduler.reserve(at: due) == .wait(milliseconds: 1_000))
    await scheduler.failed(second, at: due)
    #expect(await scheduler.reserve(at: due) == .wait(milliseconds: 60_000))
  }
}
