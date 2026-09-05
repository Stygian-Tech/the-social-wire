import Foundation
import Logging
import Testing

@testable import WireWorkerCore

@Suite("Independent Wire graph maintenance")
struct WireGraphMaintenanceRuntimeTests {
  @Test("graph work runs serially every six hours with work included in cadence")
  func sixHourCadence() async throws {
    let clock = GraphRuntimeClock()
    let sleeper = GraphRuntimeSleeper(clock: clock)
    let maintainer = GraphRuntimeMaintainer(clock: clock, outcomes: [21600, 21600])
    let state = WireWorkerHealthState()
    try await WireGraphMaintenanceRuntime.run(
      maintainer: maintainer, state: state, logger: Logger(label: "graph-runtime.tests"),
      clock: clock, sleeper: sleeper, iterationLimit: 2)
    #expect(await sleeper.delays == [21_590_000, 21_590_000])
    #expect(await maintainer.starts == [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 21_600)])
    #expect(await maintainer.maximumConcurrency == 1)
    #expect(await state.lastGraphMaintenanceAt == Date(timeIntervalSince1970: 21_610))
  }

  @Test("a previous owner's due date is honored and failure retries use bounded backoff")
  func persistedDeadlineAndRetries() async throws {
    let clock = GraphRuntimeClock()
    let sleeper = GraphRuntimeSleeper(clock: clock)
    let maintainer = GraphRuntimeMaintainer(clock: clock, outcomes: [60, nil, nil, nil, nil, nil, 21600, nil])
    try await WireGraphMaintenanceRuntime.run(
      maintainer: maintainer, state: WireWorkerHealthState(), logger: Logger(label: "graph-runtime.tests"),
      clock: clock, sleeper: sleeper, iterationLimit: 8)
    #expect(await sleeper.delays == [50_000, 60_000, 120_000, 240_000, 300_000, 300_000, 21_590_000, 60_000])
  }
}

private actor GraphRuntimeClock: WireInboxDrainClock {
  private var value = Date(timeIntervalSince1970: 0)
  func now() -> Date { value }
  func advance(seconds: Double) { value = value.addingTimeInterval(seconds) }
}

private actor GraphRuntimeSleeper: WireInboxDrainSleeping {
  let clock: GraphRuntimeClock
  var delays: [Int] = []
  init(clock: GraphRuntimeClock) { self.clock = clock }
  func sleep(milliseconds: Int) async {
    delays.append(milliseconds)
    await clock.advance(seconds: Double(milliseconds) / 1000)
  }
}

private actor GraphRuntimeMaintainer: WireGraphMaintaining {
  struct Failure: Error {}
  let clock: GraphRuntimeClock
  var outcomes: [Double?]
  var starts: [Date] = []
  var active = 0
  var maximumConcurrency = 0
  init(clock: GraphRuntimeClock, outcomes: [Double?]) {
    self.clock = clock
    self.outcomes = outcomes
  }
  func maintainGraph(asOf: Date) async throws -> Date {
    starts.append(asOf)
    active += 1
    maximumConcurrency = max(maximumConcurrency, active)
    defer { active -= 1 }
    guard let seconds = outcomes.removeFirst() else { throw Failure() }
    await clock.advance(seconds: 10)
    return asOf.addingTimeInterval(seconds)
  }
}
