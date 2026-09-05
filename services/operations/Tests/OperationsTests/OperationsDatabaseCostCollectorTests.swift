import Foundation
import Testing
@testable import Operations

@Test func databaseCostCollectorSamplesImmediatelyAndIncludesCollectionTime() async {
  let timeline = DatabaseCostTestTimeline(work: [.seconds(2), .seconds(5)])
  let collector = OperationsDatabaseCostCollector(
    collect: { _ in timeline.collect() },
    now: { timeline.now() },
    sleep: { try timeline.sleep($0) })

  await collector.runForever()

  #expect(timeline.starts == [.zero, .seconds(60)])
  #expect(timeline.sleeps == [.seconds(58), .seconds(55)])
}

@Test func databaseCostCollectorDoesNotCatchUpOrOverlapSlowPasses() async {
  let timeline = DatabaseCostTestTimeline(work: [.seconds(75), .seconds(2)])
  let collector = OperationsDatabaseCostCollector(
    collect: { _ in timeline.collect() },
    now: { timeline.now() },
    sleep: { try timeline.sleep($0) })

  await collector.runForever()

  #expect(timeline.starts == [.zero, .seconds(75)])
  #expect(timeline.sleeps == [.zero, .seconds(58)])
}

@Test func databaseCostCollectorRejectsDuplicateLoopAndStopsAfterCancelledPass() async {
  let gate = DatabaseCostCollectionGate()
  let collector = OperationsDatabaseCostCollector(
    collect: { _ in await gate.collect() },
    sleep: { _ in Issue.record("Cancelled collection must not schedule another pass") })
  let running = Task { await collector.runForever() }
  await gate.waitUntilStarted()

  // The first pass is suspended: a second entry must return without sampling.
  await collector.runForever()
  #expect(await gate.count == 1)
  running.cancel()
  await gate.release()
  await running.value
  #expect(await gate.count == 1)

  // Cancellation releases lifecycle ownership so a later service run can start again.
  let restarted = Task {
    await collector.runForever()
  }
  await gate.waitUntilStarted()
  restarted.cancel()
  await gate.release()
  await restarted.value
  #expect(await gate.count == 2)
}

@Test func databaseCostCollectorCancellationInterruptsMinuteSleep() async {
  let sleeping = DatabaseCostCollectionGate()
  let timeline = DatabaseCostTestTimeline(work: [.zero])
  let collector = OperationsDatabaseCostCollector(
    collect: { _ in timeline.collect() },
    sleep: { duration in
      await sleeping.signalStarted()
      try await Task.sleep(for: duration)
    })
  let running = Task { await collector.runForever() }
  await sleeping.waitUntilStarted()
  running.cancel()
  await running.value
  #expect(timeline.starts.count == 1)
}

@Test func databaseCostCollectorDoesNotSampleAnAlreadyCancelledTask() async {
  let timeline = DatabaseCostTestTimeline(work: [.zero])
  let collector = OperationsDatabaseCostCollector(collect: { _ in timeline.collect() })
  await Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await collector.runForever()
  }.value
  #expect(timeline.starts.isEmpty)
}

/// Synchronous clock reads require a lock; all mutable test state stays behind it.
private final class DatabaseCostTestTimeline: @unchecked Sendable {
  private let lock = NSLock()
  private let origin = ContinuousClock.now
  private let work: [Duration]
  private var elapsed: Duration = .zero
  private var recordedStarts: [Duration] = []
  private var recordedSleeps: [Duration] = []

  init(work: [Duration]) { self.work = work }

  var starts: [Duration] { lock.withLock { recordedStarts } }
  var sleeps: [Duration] { lock.withLock { recordedSleeps } }
  func now() -> ContinuousClock.Instant { lock.withLock { origin.advanced(by: elapsed) } }

  func collect() {
    lock.withLock {
      let index = recordedStarts.count
      recordedStarts.append(elapsed)
      if index < work.count { elapsed += work[index] }
    }
  }

  func sleep(_ duration: Duration) throws {
    try lock.withLock {
      recordedSleeps.append(duration)
      if recordedSleeps.count >= work.count { throw CancellationError() }
      elapsed += duration
    }
  }
}

private actor DatabaseCostCollectionGate {
  private(set) var count = 0
  private var started = false
  private var observer: CheckedContinuation<Void, Never>?
  private var continuation: CheckedContinuation<Void, Never>?

  func collect() async {
    count += 1
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      signalStarted()
    }
  }

  func signalStarted() {
    started = true
    observer?.resume()
    observer = nil
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { observer = $0 }
  }

  func release() {
    started = false
    continuation?.resume()
    continuation = nil
  }
}
