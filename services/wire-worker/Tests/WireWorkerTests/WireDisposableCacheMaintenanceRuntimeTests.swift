import Foundation
import Logging
import Testing

@testable import WireWorkerCore

@Suite("Independent disposable cache maintenance")
struct WireDisposableCacheMaintenanceRuntimeTests {
  @Test("bounded passes are paced independently of success and retried after failure")
  func pacing() async throws {
    let store = CachePruneRuntimeStore(failFirst: true)
    let sleeper = CachePruneRuntimeSleeper()
    try await WireDisposableCacheMaintenanceRuntime.run(
      store: store, logger: Logger(label: "cache-test"), sleeper: sleeper, iterationLimit: 2)
    #expect(await store.calls == 2)
    #expect(await sleeper.delays == [10_000, 30_000, 10_000])
  }

  @Test("cancellation stops maintenance without another retry")
  func cancellation() async throws {
    let store = CachePruneRuntimeStore(cancel: true)
    let sleeper = CachePruneRuntimeSleeper()
    await #expect(throws: CancellationError.self) {
      try await WireDisposableCacheMaintenanceRuntime.run(
        store: store, logger: Logger(label: "cache-test"), sleeper: sleeper, iterationLimit: 2)
    }
    #expect(await store.calls == 1)
    #expect(await sleeper.delays == [10_000])
  }
}

private actor CachePruneRuntimeSleeper: WireInboxDrainSleeping {
  var delays: [Int] = []
  func sleep(milliseconds: Int) async throws { delays.append(milliseconds) }
}

private actor CachePruneRuntimeStore: WireTalkedAccountMentionStoring {
  enum Failure: Error { case expected }
  let failFirst: Bool
  let cancel: Bool
  var calls = 0
  init(failFirst: Bool = false, cancel: Bool = false) {
    self.failFirst = failFirst
    self.cancel = cancel
  }
  func pruneExpired(asOf: Date) throws {
    calls += 1
    if cancel { throw CancellationError() }
    if failFirst, calls == 1 { throw Failure.expected }
  }
  func replaceMentions(sourceURI: String, canonicalKey: String, subjectDIDs: [String],
    speakerKeyHash: String, occurredAt: Date, expiresAt: Date) {}
  func retract(sourceURI: String, through eventTime: Date) {}
  func removeActor(did: String, actorKeyHash: String) {}
}
