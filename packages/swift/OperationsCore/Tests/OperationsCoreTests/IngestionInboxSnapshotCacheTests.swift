import Foundation
import Testing

@testable import OperationsCore

@Suite("Ingestion inbox observation cache")
struct IngestionInboxSnapshotCacheTests {
  @Test("concurrent callers share one observation and refresh at the exact TTL boundary")
  func coalescesAndExpires() async throws {
    let cache = IngestionInboxSnapshotCache()
    let now = ContinuousClock.now
    let probe = LoadProbe()
    try await withThrowingTaskGroup(of: IngestionInboxSnapshotCache.Value.self) { tasks in
      for _ in 0..<20 {
        tasks.addTask {
          try await cache.value(now: now) { await probe.load() }
        }
      }
      await probe.waitUntilStarted()
      await probe.release()
      for try await value in tasks { #expect(value["source"]?.pending == 1) }
    }
    #expect(await probe.count == 1)
    let retained = try await cache.value(now: now.advanced(by: .milliseconds(4999))) {
      await probe.load()
    }
    #expect(retained["source"]?.pending == 1)
    let refreshed = try await cache.value(now: now.advanced(by: .seconds(5))) {
      await probe.load()
    }
    #expect(refreshed["source"]?.pending == 2)
  }

  @Test("failed observations are retried instead of cached")
  func failureIsNotCached() async throws {
    enum Failure: Error { case unavailable }
    let cache = IngestionInboxSnapshotCache()
    await #expect(throws: Failure.self) {
      try await cache.value { throw Failure.unavailable }
    }
    let value = try await cache.value { ["recovered": .init(pending: 3)] }
    #expect(value["recovered"]?.pending == 3)
  }

  @Test("global metrics preserve every counter and advance oldest age without a database refresh")
  func aggregationAndAge() {
    let start = Date(timeIntervalSince1970: 1_000)
    let sources = [
      IngestionInboxMetrics(
        pending: 2, leased: 3, retrying: 4, applied: 5, filteredScope: 6,
        deadLetters: 7, total: 29, oldestPendingAt: start),
      IngestionInboxMetrics(
        pending: 11, leased: 12, retrying: 13, applied: 14, filteredScope: 15,
        deadLetters: 16, total: 89, oldestPendingAt: start.addingTimeInterval(10)),
    ]
    let total = IngestionInboxSnapshotCache.total(sources, at: start.addingTimeInterval(30))
    #expect(
      total
        == IngestionInboxMetrics(
          pending: 13, leased: 15, retrying: 17, applied: 19, filteredScope: 21,
          deadLetters: 23, total: 118, oldestPendingAt: start, oldestPendingAgeSeconds: 30))
    #expect(
      IngestionInboxSnapshotCache.aged(total, at: start.addingTimeInterval(34))
        .oldestPendingAgeSeconds == 34)
    #expect(IngestionInboxSnapshotCache.total([], at: start) == IngestionInboxMetrics())
    #expect(IngestionInboxSnapshotCache.aged(sources[1], at: start).oldestPendingAgeSeconds == 0)
  }

  private actor LoadProbe {
    var count = 0
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async -> IngestionInboxSnapshotCache.Value {
      count += 1
      let result = count
      for waiter in startedWaiters { waiter.resume() }
      startedWaiters.removeAll()
      if !released {
        await withCheckedContinuation { loadWaiters.append($0) }
      }
      return ["source": .init(pending: result)]
    }

    func waitUntilStarted() async {
      if count > 0 { return }
      await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
      released = true
      for waiter in loadWaiters { waiter.resume() }
      loadWaiters.removeAll()
    }
  }
}
