import Foundation
import Testing
@testable import ThinAppViewCore

@Suite("Bounded feed request timings")
struct AppViewFeedRequestTimingsTests {
  private actor Reader {
    var count = 0
    func read() async -> Int {
      await AppViewFeedRequestTimings.measure(.readState) {
        count += 1
        return count
      }
    }
  }

  @Test("measurement preserves caller actor isolation and explicitly excluded background work")
  func actorAndBackgroundIsolation() async {
    let timings = AppViewFeedRequestTimings()
    let reader = Reader()
    await AppViewFeedRequestTimings.$current.withValue(timings) {
      #expect(await reader.read() == 1)
      let background = AppViewFeedRequestTimings.$current.withValue(nil) {
        Task { await reader.read() }
      }
      #expect(await background.value == 2)
    }
    #expect(timings.finish()["read_state_count"] == 1)
  }

  @Test("monotonic stage and database timings have fixed keys and idempotent completion")
  func fixedSnapshot() {
    let timings = AppViewFeedRequestTimings()
    let start = ContinuousClock.now
    AppViewFeedRequestTimings.$current.withValue(timings) {
      let span = AppViewFeedRequestTimings.start(.publicationSelect, at: start)
      span?.finish(at: start.advanced(by: .milliseconds(25)))
      span?.finish(at: start.advanced(by: .seconds(1)))
      AppViewFeedRequestTimings.startPoolWait(at: start)?.finish(at: start.advanced(by: .milliseconds(5)))
      AppViewFeedRequestTimings.startTransaction(at: start)?.finish(at: start.advanced(by: .milliseconds(20)))
      AppViewFeedRequestTimings.recordQuery()
      AppViewFeedRequestTimings.recordQuery()
    }
    let result = timings.finish()
    #expect(result["publication_select_ms"] == 25)
    #expect(result["publication_select_count"] == 1)
    #expect(result["pg_pool_wait_ms"] == 5)
    #expect(result["pg_transaction_ms"] == 20)
    #expect(result["pg_query_count"] == 2)
    let stages = ["cache_lookup", "refresh_lease", "publication_select", "cache_store", "read_state", "pg_pool_wait", "pg_transaction"]
    #expect(Set(result.keys) == Set(stages.flatMap { [$0 + "_ms", $0 + "_count"] } + ["pg_query_count"]))
  }

  @Test("concurrent child stages aggregate without crossing request contexts")
  func concurrentRequests() async {
    let first = AppViewFeedRequestTimings()
    let second = AppViewFeedRequestTimings()
    await withTaskGroup(of: Void.self) { group in
      for timings in [first, second] {
        group.addTask {
          await AppViewFeedRequestTimings.$current.withValue(timings) {
            await withTaskGroup(of: Void.self) { children in
              for _ in 0..<50 {
                children.addTask {
                  let start = ContinuousClock.now
                  AppViewFeedRequestTimings.start(.readState, at: start)?
                    .finish(at: start.advanced(by: .milliseconds(2)))
                  AppViewFeedRequestTimings.recordQuery()
                }
              }
            }
          }
        }
      }
    }
    for timings in [first, second] {
      let snapshot = timings.finish()
      #expect(snapshot["read_state_count"] == 50)
      #expect(snapshot["read_state_ms"] == 100)
      #expect(snapshot["pg_query_count"] == 50)
    }
    #expect(AppViewFeedRequestTimings.current == nil)
  }

  @Test("measurement preserves thrown cancellation and the original request deadline")
  func cancellationAndDeadline() async {
    let timings = AppViewFeedRequestTimings()
    let deadline = AppViewFeedQueryDeadline()
    await AppViewFeedRequestTimings.$current.withValue(timings) {
      await AppViewFeedQueryDeadline.$current.withValue(deadline) {
        do {
          try await AppViewFeedRequestTimings.measure(.cacheLookup) {
            #expect(AppViewFeedQueryDeadline.current?.instant == deadline.instant)
            throw CancellationError()
          }
          Issue.record("Cancellation was swallowed")
        } catch { #expect(error is CancellationError) }
      }
    }
    #expect(timings.finish()["cache_lookup_count"] == 1)
  }

  @Test("late spans cannot change a completed request and counters are capped")
  func sealedAndBounded() {
    let timings = AppViewFeedRequestTimings()
    let start = ContinuousClock.now
    AppViewFeedRequestTimings.$current.withValue(timings) {
      let late = AppViewFeedRequestTimings.start(.cacheStore, at: start)
      for _ in 0..<10_010 { AppViewFeedRequestTimings.recordQuery() }
      AppViewFeedRequestTimings.start(.readState, at: start)?
        .finish(at: start.advanced(by: .seconds(7_200)))
      let first = timings.finish()
      #expect(first["pg_query_count"] == 10_000)
      #expect(first["read_state_ms"] == 3_600_000)
      late?.finish()
      AppViewFeedRequestTimings.recordQuery()
      #expect(timings.finish() == first)
    }
  }
}
