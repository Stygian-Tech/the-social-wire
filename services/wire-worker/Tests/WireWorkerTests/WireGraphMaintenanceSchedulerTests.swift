import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Wire graph scheduling across ownership changes")
struct WireGraphMaintenanceSchedulerTests {
  @Test("initial grace and pending attempts survive a replacement owner")
  func initialGrace() async throws {
    let scheduler = WireGraphMaintenanceScheduler()
    let start = ContinuousClock.now
    #expect(await scheduler.reserve(at: start) == .wait(milliseconds: 60_000))
    #expect(await scheduler.reserve(at: start.advanced(by: .seconds(20))) == .wait(milliseconds: 40_000))
    guard case .run = await scheduler.reserve(at: start.advanced(by: .seconds(60))) else {
      Issue.record("Graph work did not become available after its initial grace period")
      return
    }
  }

  @Test("canceled attempts retain exponential backoff across host recreation")
  func cancellationBackoff() async throws {
    let scheduler = WireGraphMaintenanceScheduler(initialDelayMilliseconds: 0)
    var now = ContinuousClock.now
    for delay in [60_000, 120_000, 240_000, 300_000, 300_000] {
      guard case .run(let token) = await scheduler.reserve(at: now) else {
        Issue.record("Expected graph ownership after the retry deadline")
        return
      }
      #expect(await scheduler.failed(token, at: now) == delay)
      #expect(await scheduler.reserve(at: now) == .wait(milliseconds: delay))
      now = now.advanced(by: .milliseconds(delay))
    }
  }

  @Test("active work never overlaps and stale completion cannot release a replacement")
  func noOverlapAndStaleCompletion() async throws {
    let scheduler = WireGraphMaintenanceScheduler(initialDelayMilliseconds: 0)
    let start = ContinuousClock.now
    guard case .run(let first) = await scheduler.reserve(at: start) else {
      Issue.record("Expected the first graph attempt")
      return
    }
    #expect(await scheduler.reserve(at: start.advanced(by: .seconds(60))) == .wait(milliseconds: 1_000))
    #expect(await scheduler.failed(first, at: start) == 60_000)
    let later = start.advanced(by: .seconds(60))
    guard case .run(let replacement) = await scheduler.reserve(at: later) else {
      Issue.record("Expected a replacement after failure backoff")
      return
    }
    await scheduler.succeeded(first, at: later, nextDelayMilliseconds: 1_000)
    #expect(await scheduler.failed(first, at: later) == nil)
    #expect(await scheduler.reserve(at: later) == .wait(milliseconds: 1_000))
    await scheduler.succeeded(replacement, at: later, nextDelayMilliseconds: 21_600_000)
    #expect(await scheduler.reserve(at: later) == .wait(milliseconds: 21_600_000))
    let due = later.advanced(by: .seconds(21_600))
    guard case .run(let next) = await scheduler.reserve(at: due) else {
      Issue.record("Expected work after the successful six-hour cadence")
      return
    }
    #expect(await scheduler.failed(next, at: due) == 60_000)
  }
}
