import Foundation
import Logging
import Testing
@testable import WireWorkerCore

@Suite("Bounded recommendation recovery runtime")
struct WireRecommendationRecoveryRuntimeTests {
  @Test("dependency recovery has bounded batches and independent backoff")
  func boundedRecovery() async throws {
    let journal = RecoveryJournalStub(failFirst: true)
    let sleeper = RecoverySleeperStub()
    let scope = WireInboxSourceScope(environment: "test", sourceGenerations: ["live"])
    try await WireRecommendationRecoveryRuntime.run(
      journal: journal, sourceScope: scope, logger: Logger(label: "recovery-test"),
      clock: RecoveryClockStub(), sleeper: sleeper, iterationLimit: 3)
    #expect(await journal.limits == [16, 16, 16])
    #expect(await journal.environments == ["test", "test", "test"])
    #expect(await sleeper.delays == [30_000, 5_000, 5_000])
    #expect(await journal.backlogCalls == 1)
  }

  @Test("cancellation stops recovery without retrying or sleeping")
  func cancellation() async throws {
    let journal = RecoveryJournalStub(cancel: true)
    let sleeper = RecoverySleeperStub()
    await #expect(throws: CancellationError.self) {
      try await WireRecommendationRecoveryRuntime.run(
        journal: journal, sourceScope: nil, logger: Logger(label: "recovery-test"),
        clock: RecoveryClockStub(), sleeper: sleeper, iterationLimit: 3)
    }
    #expect(await journal.limits == [16])
    #expect(await sleeper.delays.isEmpty)
  }
}

private actor RecoveryJournalStub: WireRecommendationRecovering {
  enum Failure: Error { case unavailable }
  let failFirst: Bool
  let cancel: Bool
  var limits: [Int] = []
  var environments: [String?] = []
  var backlogCalls = 0

  init(failFirst: Bool = false, cancel: Bool = false) {
    self.failFirst = failFirst
    self.cancel = cancel
  }

  func recover(asOf: Date, limit: Int, sourceScope: WireInboxSourceScope?) throws
    -> WireRecommendationRecoveryCounts
  {
    limits.append(limit)
    environments.append(sourceScope?.environment)
    if cancel { throw CancellationError() }
    if failFirst && limits.count == 1 { throw Failure.unavailable }
    return .init(attempted: 1, pending: 1)
  }

  func backlog(asOf: Date, sourceScope: WireInboxSourceScope?) -> WireRecommendationBacklog {
    backlogCalls += 1
    return .init(pendingCount: 1, conflictCount: 0, oldestPendingAgeSeconds: 600,
      oldestConflictAgeSeconds: 0, countLimit: 1000)
  }
}

private actor RecoverySleeperStub: WireInboxDrainSleeping {
  var delays: [Int] = []
  func sleep(milliseconds: Int) { delays.append(milliseconds) }
}

private struct RecoveryClockStub: WireInboxDrainClock {
  func now() -> Date { Date(timeIntervalSince1970: 2_000_000_000) }
}
